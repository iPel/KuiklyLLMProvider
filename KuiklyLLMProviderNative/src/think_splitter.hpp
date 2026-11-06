#pragma once

// 把模型输出切分为「思考」与「正文」的流式切分器。
//
// 独立成头文件便于在宿主机执行单元测试（见 tests/think_splitter_test.cpp）。
// 覆盖的边界包括：标签被词元切开、UTF-8 字符被切开、模型再次开启思考块。

#include "engine.hpp"

#include <cstring>
#include <string>

namespace llm_provider {

// Qwen3 的思考块标签。注意 "</think>" 不含 "<think>"，两者用 find 匹配不会互相误判。
constexpr const char* kThinkOpenTag = "<think>";
constexpr const char* kThinkCloseTag = "</think>";

/**
 * 对应 llama-server 的 --reasoning-format deepseek：思考进 reasoning_content，
 * 正文进 content，两者的分界就是 <think> / </think> 标签本身。
 *
 * 实现方式是逐个扫描标签并维护状态，而不是只在开头判断一次。小模型在思考预算
 * 耗尽时，常会写完当前语句后补上一个 </think>，甚至再次开启一个 <think>。
 * 逐个处理标签，才能保证任何位置的标签都不会混入正文。
 *
 * 流结束时若 </think> 仍缺失，不会补写该标签，以免掩盖真正的输出截断。
 * 已生成的思考照实归入 reasoning，由 finish_reason="length" 告知调用方。
 */
class ThinkSplitter {
public:
    void feed(const std::string& piece, std::string& out_reasoning, std::string& out_content) {
        buf_ += piece;
        pump(false, out_reasoning, out_content);
    }

    void finish(std::string& out_reasoning, std::string& out_content) {
        pump(true, out_reasoning, out_content);
    }

private:
    void emit(const std::string& text, std::string& out_reasoning, std::string& out_content) {
        if (text.empty()) return;
        if (in_think_) {
            out_reasoning += text;
            return;
        }
        std::string body = text;
        // 两种情况下正文开头的空白没有意义，直接裁掉：
        //   1) 刚闭合思考块（模型常跟两个换行）
        //   2) 整段正文还一个字都没写（模型在 <think> 前可能先输出一个换行）
        // 判断依据必须是切分器自己的状态，不能用 out_content.empty()：流式
        // 回调每次 token 都传入全新的输出缓冲，用它会把每个词元的前导空格
        // 一并裁掉，拼出 "RunninganLLM" 这类粘连文本。
        if (skip_leading_ws_ || !content_started_) {
            size_t ws = 0;
            while (ws < body.size() && (body[ws] == ' ' || body[ws] == '\n' ||
                                        body[ws] == '\r' || body[ws] == '\t')) {
                ++ws;
            }
            body.erase(0, ws);
            if (!body.empty()) {
                skip_leading_ws_ = false;
                content_started_ = true;
            }
            if (body.empty()) return;
        }
        out_content += body;
    }

    void pump(bool final, std::string& out_reasoning, std::string& out_content) {
        const size_t open_len = std::strlen(kThinkOpenTag);
        const size_t close_len = std::strlen(kThinkCloseTag);
        // 标签可能被 token 边界切开，尾部最多留 (最长标签 - 1) 字节等下一次补齐
        const size_t hold = (open_len > close_len ? open_len : close_len) - 1;

        while (true) {
            const size_t open_at = buf_.find(kThinkOpenTag);
            const size_t close_at = buf_.find(kThinkCloseTag);
            size_t at = std::string::npos;
            bool is_open = false;
            if (open_at != std::string::npos &&
                (close_at == std::string::npos || open_at < close_at)) {
                at = open_at;
                is_open = true;
            } else if (close_at != std::string::npos) {
                at = close_at;
            }

            if (at == std::string::npos) {
                // 没有完整标签：把尾部可能被切开的半个标签留下，其余先输出
                if (buf_.size() > hold) {
                    const size_t want = buf_.size() - hold;
                    // 别在多字节字符中间切开，否则会出现半个汉字/emoji
                    const size_t flush = utf8_complete_prefix_len(buf_.substr(0, want));
                    if (flush > 0) {
                        emit(buf_.substr(0, flush), out_reasoning, out_content);
                        buf_.erase(0, flush);
                    }
                }
                if (final && !buf_.empty()) {
                    emit(buf_, out_reasoning, out_content);
                    buf_.clear();
                }
                return;
            }

            if (at > 0) {
                emit(buf_.substr(0, at), out_reasoning, out_content);
                buf_.erase(0, at);
            }
            buf_.erase(0, is_open ? open_len : close_len);
            in_think_ = is_open;
            if (!is_open) skip_leading_ws_ = true;
        }
    }

    bool in_think_ = false;
    bool skip_leading_ws_ = false;
    // 整段正文是否已输出过非空内容，跨多次 feed 保持。
    bool content_started_ = false;
    std::string buf_;
};

}  // namespace llm_provider
