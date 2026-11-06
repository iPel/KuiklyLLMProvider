#pragma once
#include <atomic>
#include <chrono>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace llm_provider {

struct ChatMessage {
    std::string role;
    std::string content;
};

struct GenerateOptions {
    int max_tokens = 1024;
    float temperature = 0.7f;

    /**
     * 思考预算（token 数），用于解决 Qwen3 思考标签未闭合的问题。
     *
     *   -1  不限（原始行为，长思考会在 <think> 中途被 max_tokens 截断）
     *    0  完全关闭思考：把空的 <think></think> 预填进 assistant 回合，
     *       模型直接作答，不会产生未闭合标签
     *   >0  思考最多这么多 token。超预算时把 "</think>\n\n" 作为强制序列
     *       写入 KV cache，再交回正常采样继续作答。
     *
     * 强制序列必须进入 KV，模型后续作答才基于「思考已结束」的上下文。
     * 这里用 llama.cpp 的 tokenize + decode 实现，不链接 common。
     */
    int reasoning_budget = -1;

    // 取消标志。引擎在每个生成步检查，置位后尽快停止并回收；
    // 由 HttpServer 在 stop() 时置位，引擎只读、不接管所有权。
    // 客户端断开不经此标志，而是由 sink 返回 false 终止生成。
    // 为空表示不启用取消（例如单元测试里的独立调用）。
    const std::atomic<bool>* cancel = nullptr;

    // 生成截止时刻；steady_clock::time_point::max() 表示不限。
    // 引擎每步检查，超时即停止，避免 SSE 断开或卡死时仍生成到 max_tokens 上限。
    std::chrono::steady_clock::time_point deadline =
        std::chrono::steady_clock::time_point::max();
};

// 失败分类，供 HTTP 层映射状态码（详细原因见 get_last_error()）。
enum class GenerateError {
    None,
    NoModel,          // 未加载模型（含检查后被卸载的竞态）→ 400
    ContextOverflow,  // prompt 超出上下文窗口 → 400
    Engine,           // tokenize / decode / sampler 等引擎内部失败 → 500
};

// 生成结果统一按值返回，统计与结束原因集中在 GenerateResult，
// 避免指针出参带来的悬空指针与所有权问题。
struct GenerateResult {
    int prompt_tokens = 0;
    int completion_tokens = 0;
    // "stop" 自然结束 / "length" 达到上限或超时 / "error" 引擎失败 / "cancelled" 取消。
    std::string finish_reason = "stop";
    GenerateError error = GenerateError::None;
};

// sink 返回 bool —— true 继续生成；false 表示下游（如 SSE 客户端断开、
// send 失败）要求提前终止。引擎必须检查返回值并在 false 时尽快退出循环。
using TokenSink = std::function<bool(const std::string&)>;

class Engine {
public:
    virtual ~Engine() = default;
    virtual std::string name() const = 0;
    virtual bool model_loaded() const = 0;
    virtual bool load(const std::string& model_path) = 0;
    // generate 返回统计信息；期间通过 sink 逐段输出。实现方须遵守
    // options.cancel / options.deadline 与 sink 的 bool 返回值。
    virtual GenerateResult generate(const std::vector<ChatMessage>& messages,
                                    const std::string& raw_prompt,
                                    const GenerateOptions& options,
                                    const TokenSink& sink) = 0;
    // close() 释放底层权重/上下文；与 generate 的并发由 HttpServer 的
    // engine_mutex 串行化，实现方不自行假设可并发调用。
    virtual void close() = 0;
};

/**
 * 唯一的推理引擎实现。编译期必须定义 LLMPROVIDER_WITH_LLAMA 并链接
 * llama.cpp + ggml，否则 llama_engine.cpp 直接 #error；不存在备用 / 模拟引擎。
 * 返回的是「未加载模型」的实例，需调用 load() 成功后才可生成内容。
 */
std::unique_ptr<Engine> create_llama_engine(int n_ctx, int n_threads);

/** Qwen 系列 ChatML 后备模板；llama.cpp 引擎优先使用 GGUF 内置 chat_template。 */
std::string build_chatml_prompt(const std::vector<ChatMessage>& messages,
                                const std::string& raw_prompt);

/**
 * 最近一次引擎失败原因。C API / NAPI 会把它透出到 ArkTS，
 * 便于在设备上确认引擎失败原因（移动端无法查看 stderr）。
 */
void set_last_error(const std::string& message);
std::string get_last_error();

/**
 * 返回 s 中「完整 UTF-8 字符」前缀的字节长度。
 *
 * llama_token_to_piece 在多字节字符正好被 token 边界切开时，会产生半个字符的
 * 字节序列（例如某个 emoji 的前 2 个字节）。这些字节直接写入 JSON 会产生非法
 * UTF-8，客户端解析失败丢包，界面上表现为乱码或字符缺失。
 * 正确做法是把不完整的末尾字节截下来，等下一个 token 补全后再一起发送。
 */
inline size_t utf8_complete_prefix_len(const std::string& s) {
    const size_t n = s.size();
    size_t i = n;
    size_t back = 0;
    while (i > 0 && back < 4) {
        --i;
        ++back;
        const unsigned char c = static_cast<unsigned char>(s[i]);
        if ((c & 0x80) == 0) return n;  // ASCII 字符本身完整
        if ((c & 0xC0) == 0xC0) {       // 多字节字符的首字节
            size_t need = 1;
            if ((c & 0xE0) == 0xC0) need = 2;
            else if ((c & 0xF0) == 0xE0) need = 3;
            else if ((c & 0xF8) == 0xF0) need = 4;
            return (n - i) >= need ? n : i;
        }
        // 0x80..0xBF 是续字节，继续往前找首字节
    }
    return n;
}

}  // namespace llm_provider
