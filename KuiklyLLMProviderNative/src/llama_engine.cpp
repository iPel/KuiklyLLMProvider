// 编译必须定义 LLMPROVIDER_WITH_LLAMA=1 并链接 llama.cpp + ggml。
#ifndef LLMPROVIDER_WITH_LLAMA
#error "llm_provider requires llama.cpp: define LLMPROVIDER_WITH_LLAMA=1 and link libllama.a + libggml*.a"
#endif

#include "engine.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <sys/stat.h>

#include "llama.h"

namespace llm_provider {

namespace {
std::once_flag g_backend_once;

/** 把文件前 8 字节转十六进制并附上大小，用于校验 GGUF 文件头。 */
std::string describe_file(const std::string& path) {
    struct stat st;
    std::ostringstream out;
    if (::stat(path.c_str(), &st) != 0) {
        return "stat-failed";
    }
    out << "size=" << static_cast<long long>(st.st_size) << " head=";
    std::ifstream in(path.c_str(), std::ios::binary);
    if (!in) {
        out << "open-failed";
        return out.str();
    }
    char buf[8] = {0};
    in.read(buf, 8);
    const std::streamsize got = in.gcount();
    out << "[";
    for (std::streamsize i = 0; i < got; ++i) {
        char hex[8];
        std::snprintf(hex, sizeof(hex), "%02x",
                      static_cast<unsigned char>(buf[i]));
        out << hex;
    }
    out << "]";
    return out.str();
}
}  // namespace

namespace {

std::string apply_chat_template(llama_model* model,
                                const std::vector<ChatMessage>& messages,
                                const std::string& raw_prompt) {
    std::vector<llama_chat_message> chat;
    chat.reserve(messages.size());
    for (const auto& m : messages) {
        chat.push_back(llama_chat_message{m.role.c_str(), m.content.c_str()});
    }
    const char* tmpl = llama_model_chat_template(model, nullptr);
    if (tmpl != nullptr && !chat.empty()) {
        size_t total = 0;
        for (const auto& m : messages) total += m.role.size() + m.content.size();
        // 官方文档建议分配 2 * 消息总字符数。
        std::vector<char> buffer(2 * total + 1024);
        // llama_chat_apply_template 返回格式化 prompt 所需字节数；大于缓冲区长度时
        // 按返回值扩容后重新调用。written 超过 buffer.size() 即需扩容。
        int32_t written = llama_chat_apply_template(
            tmpl, chat.data(), chat.size(), true, buffer.data(),
            static_cast<int32_t>(buffer.size()));
        if (written > static_cast<int32_t>(buffer.size())) {
            buffer.resize(static_cast<size_t>(written) + 1);
            written = llama_chat_apply_template(
                tmpl, chat.data(), chat.size(), true, buffer.data(),
                static_cast<int32_t>(buffer.size()));
        }
        if (written > 0) return std::string(buffer.data(), static_cast<size_t>(written));
    }
    // GGUF 未带模板时回退到 Qwen ChatML。
    return build_chatml_prompt(messages, raw_prompt);
}

// ---- 思考块（<think>…</think>）识别 ----
constexpr const char* kThinkOpen = "<think>";
constexpr const char* kThinkClose = "</think>";
constexpr size_t kTagWindow = 32;
// 思考预算触发时强制写入 KV 的 "</think>\n\n" 预留 token 数（实际约 2~4 个，留足余量）；
// 每次生成至多强制写入一次（forced_answer 后不再进入思考态）。
constexpr int32_t kForceFeedReserve = 16;

void append_keep_tail(std::string& tail, const std::string& piece) {
    tail += piece;
    if (tail.size() > kTagWindow) tail.erase(0, tail.size() - kTagWindow);
}
}  // namespace

class LlamaEngine final : public Engine {
public:
    LlamaEngine(int n_ctx, int n_threads) : n_ctx_(n_ctx), n_threads_(n_threads) {}
    ~LlamaEngine() override { close(); }

    std::string name() const override { return "llama.cpp"; }
    bool model_loaded() const override { return model_ != nullptr && ctx_ != nullptr; }

    bool load(const std::string& model_path) override {
        if (model_path.empty()) return false;
        std::call_once(g_backend_once, [] { llama_backend_init(); });
        close();

        llama_model_params mparams = llama_model_default_params();
        mparams.n_gpu_layers = 0;  // 移动端纯 CPU 推理
        model_ = llama_model_load_from_file(model_path.c_str(), mparams);
        if (model_ == nullptr) {
            set_last_error("llama_model_load_from_file failed: " + model_path +
                           " (" + describe_file(model_path) + ")");
            return false;
        }

        llama_context_params cparams = llama_context_default_params();
        cparams.n_ctx = static_cast<uint32_t>(n_ctx_);
        cparams.n_batch = 512;
        cparams.n_ubatch = 512;
        cparams.n_threads = n_threads_;
        cparams.n_threads_batch = n_threads_;
        ctx_ = llama_init_from_model(model_, cparams);
        if (ctx_ == nullptr) {
            set_last_error("llama_init_from_model failed (n_ctx=" + std::to_string(n_ctx_) + ")");
            llama_model_free(model_);
            model_ = nullptr;
            return false;
        }
        set_last_error("");
        return true;
    }

    GenerateResult generate(const std::vector<ChatMessage>& messages,
                            const std::string& raw_prompt,
                            const GenerateOptions& options,
                            const TokenSink& sink) override {
        if (!model_loaded()) {
            // 无模型是显式的错误状态：HTTP 层已用 400 提前拒绝，这里额外防护
            // 「检查后恰好发生 unload」的竞态，绝不生成假回复。
            set_last_error("no GGUF model loaded; call llmprovider_load_model() first");
            GenerateResult result;
            result.finish_reason = "error";
            result.error = GenerateError::NoModel;
            return result;
        }
        GenerateResult result;
        // 任何退出路径（含 prompt decode / sampler 初始化失败）都清空 KV cache：
        // 残留 token 会被 llama_batch_get_one 的自动位置续接到下一次请求，造成串扰。
        // llama_get_memory 可能返回 NULL，必须判空。
        struct KvClearGuard {
            llama_context* ctx;
            ~KvClearGuard() {
                llama_memory_t mem = (ctx != nullptr) ? llama_get_memory(ctx) : nullptr;
                if (mem != nullptr) llama_memory_clear(mem, true);
            }
        } kv_guard{ctx_};
        const llama_vocab* vocab = llama_model_get_vocab(model_);
        std::string prompt = apply_chat_template(model_, messages, raw_prompt);

        // 思考预算为 0：预填一个空的思考块，让模型跳过思考直接作答。
        if (options.reasoning_budget == 0 &&
            prompt.find("<|im_start|>") != std::string::npos) {
            prompt += std::string(kThinkOpen) + "\n\n" + kThinkClose + "\n\n";
        }

        int32_t capacity = static_cast<int32_t>(prompt.size()) + 64;
        std::vector<llama_token> tokens(static_cast<size_t>(capacity));
        int32_t n_tokens = llama_tokenize(vocab, prompt.c_str(),
                                           static_cast<int32_t>(prompt.size()),
                                           tokens.data(), capacity, true, true);
        if (n_tokens < 0) {
            capacity = -n_tokens;
            tokens.resize(static_cast<size_t>(capacity));
            n_tokens = llama_tokenize(vocab, prompt.c_str(),
                                      static_cast<int32_t>(prompt.size()),
                                      tokens.data(), capacity, true, true);
        }
        if (n_tokens <= 0) {
            set_last_error("llama_tokenize returned no tokens");
            result.finish_reason = "error";
            result.error = GenerateError::Engine;
            return result;
        }
        tokens.resize(static_cast<size_t>(n_tokens));
        result.prompt_tokens = n_tokens;

        // 上下文预算：prompt + 生成 token + 思考预算强制写入的 "</think>\n\n" 都占 KV。
        // 预检放在 decode 之前，超限立即返回、不做无用的 prompt 计算；
        // 生成上限收紧到剩余容量，避免中途 decode 因 KV 满而失败。
        const int32_t n_ctx = static_cast<int32_t>(llama_n_ctx(ctx_));
        const int32_t available = n_ctx - n_tokens - kForceFeedReserve;
        if (available < 1) {
            set_last_error("prompt is " + std::to_string(n_tokens) +
                           " tokens; exceeds context window of " + std::to_string(n_ctx) +
                           " tokens");
            result.finish_reason = "error";
            result.error = GenerateError::ContextOverflow;
            return result;
        }

        // 单次 decode 的 token 数受 n_batch(=512) 限制，因此按 n_batch 分批 decode；
        // 任何一批失败都回填 finish_reason 与 last_error。
        constexpr int32_t kN_batch = 512;  // 与 cparams.n_batch 保持一致
        for (int32_t off = 0; off < n_tokens; off += kN_batch) {
            const int32_t count = std::min(kN_batch, n_tokens - off);
            llama_batch batch = llama_batch_get_one(tokens.data() + off, count);
            if (llama_decode(ctx_, batch) != 0) {
                set_last_error("llama_decode(prompt) failed at offset " +
                               std::to_string(off) + " (" + std::to_string(count) +
                               " tokens)");
                result.finish_reason = "error";
                result.error = GenerateError::Engine;
                return result;
            }
        }

        // sampler 用 RAII 管理（异常/提前返回路径都会释放），并判空。
        llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
        llama_sampler* raw_sampler = llama_sampler_chain_init(sparams);
        if (raw_sampler == nullptr) {
            set_last_error("llama_sampler_chain_init returned nullptr");
            result.finish_reason = "error";
            result.error = GenerateError::Engine;
            return result;
        }
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
            raw_sampler, &llama_sampler_free);
        llama_sampler_chain_add(sampler.get(),
            llama_sampler_init_temp(std::max(0.01f, options.temperature)));
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(40));
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(0.9f, 1));
        // 随机种子：固定种子会让相同输入总得到相同输出，「重新生成」失效。
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

        const int limit = std::min({std::max(options.max_tokens, 1), 4096, available});
        // 默认按「达到 max_tokens 上限 / 超时」计算；自然遇到 EOG 再改写成 stop。
        result.finish_reason = "length";
        bool hard_failure = false;  // decode 失败
        bool sink_stopped = false;  // 下游（SSE）要求提前终止

        // 统一出口：保证交给 sink 的每一段都是合法 UTF-8；返回 sink 的 bool 结果。
        std::string utf8_pending;
        auto emit_text = [&](const std::string& text) -> bool {
            if (text.empty()) return true;
            utf8_pending += text;
            const size_t ok = utf8_complete_prefix_len(utf8_pending);
            if (ok == 0) return true;
            const bool keep_going = sink(utf8_pending.substr(0, ok));
            utf8_pending.erase(0, ok);
            return keep_going;
        };

        // 将强制生成的标签写入 KV cache，但不发送给客户端。返回是否成功。
        auto force_feed = [&](const std::string& text) -> bool {
            std::vector<llama_token> buf(text.size() + 8);
            int32_t count = llama_tokenize(vocab, text.c_str(),
                                           static_cast<int32_t>(text.size()),
                                           buf.data(), static_cast<int32_t>(buf.size()),
                                           /*add_special=*/false, /*parse_special=*/true);
            if (count < 0) {
                buf.resize(static_cast<size_t>(-count));
                count = llama_tokenize(vocab, text.c_str(),
                                       static_cast<int32_t>(text.size()),
                                       buf.data(), static_cast<int32_t>(buf.size()),
                                       false, true);
            }
            for (int32_t k = 0; k < count; ++k) {
                llama_batch fb = llama_batch_get_one(&buf[static_cast<size_t>(k)], 1);
                if (llama_decode(ctx_, fb) != 0) {
                    set_last_error("llama_decode(force_feed) failed");
                    return false;
                }
            }
            return true;
        };

        bool in_think = false;
        bool forced_answer = false;
        int think_tokens = 0;
        std::string tag_tail;

        // 将输出从思考态切换到正文态：闭合标签同时写入 KV cache 并发送给客户端。
        auto enter_answer = [&]() {
            const std::string close = std::string(kThinkClose) + "\n\n";
            if (!force_feed(close)) { hard_failure = true; return; }
            if (!emit_text(close)) { sink_stopped = true; return; }
            forced_answer = true;
            in_think = false;
            tag_tail.clear();
        };

        for (int i = 0; i < limit; ++i) {
            // 每步检查取消标志与截止时间，SSE 断开或超时时不会继续生成到 4096 token 上限。
            if (options.cancel && options.cancel->load()) {
                result.finish_reason = "cancelled";
                break;
            }
            if (std::chrono::steady_clock::now() >= options.deadline) {
                result.finish_reason = "length";
                break;
            }
            // llama_batch_get_one 需要非 const 的 llama_token*，这里不能声明为 const。
            llama_token id = llama_sampler_sample(sampler.get(), ctx_, -1);
            if (llama_vocab_is_eog(vocab, id)) {
                if (in_think && !forced_answer) {
                    enter_answer();
                    if (hard_failure || sink_stopped) break;
                    continue;  // EOG 不进入上下文，避免中断生成序列
                }
                result.finish_reason = "stop";
                break;
            }
            char piece[256];
            const int32_t n = llama_token_to_piece(vocab, id, piece,
                                                   static_cast<int32_t>(sizeof(piece)), 0, true);
            const std::string text = n > 0 ? std::string(piece, static_cast<size_t>(n)) : std::string();
            // sink 返回 false（客户端断开 / send 失败）立即终止生成。
            if (!emit_text(text)) { sink_stopped = true; break; }
            ++result.completion_tokens;
            llama_batch next = llama_batch_get_one(&id, 1);
            if (llama_decode(ctx_, next) != 0) {
                set_last_error("llama_decode(next) failed");
                hard_failure = true;
                result.finish_reason = "error";
                break;
            }

            // 维护思考块状态与已用 token 数。
            append_keep_tail(tag_tail, text);
            if (!in_think) {
                if (!forced_answer && tag_tail.find(kThinkOpen) != std::string::npos) {
                    in_think = true;
                    think_tokens = 0;
                    tag_tail.clear();
                }
            } else if (tag_tail.find(kThinkClose) != std::string::npos) {
                in_think = false;
                tag_tail.clear();
            } else {
                ++think_tokens;
                if (options.reasoning_budget >= 0 && think_tokens > options.reasoning_budget) {
                    enter_answer();
                    if (hard_failure || sink_stopped) break;
                }
            }
        }
        // 收尾：把未凑齐的末尾字节一并发送（通常为空）。
        if (!utf8_pending.empty() && !sink_stopped) {
            if (!sink(utf8_pending)) sink_stopped = true;
            utf8_pending.clear();
        }
        if (hard_failure) {
            result.finish_reason = "error";
            result.error = GenerateError::Engine;
        }
        // sampler（unique_ptr）与 KV cache（kv_guard）在此及所有提前返回路径自动回收。
        return result;
    }

    void close() override {
        if (ctx_ != nullptr) { llama_free(ctx_); ctx_ = nullptr; }
        if (model_ != nullptr) { llama_model_free(model_); model_ = nullptr; }
    }

private:
    int n_ctx_;
    int n_threads_;
    llama_model* model_ = nullptr;
    llama_context* ctx_ = nullptr;
};

std::unique_ptr<Engine> create_llama_engine(int n_ctx, int n_threads) {
    return std::unique_ptr<Engine>(new LlamaEngine(n_ctx, n_threads));
}

}  // namespace llm_provider
