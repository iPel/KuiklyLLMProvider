// 共享引擎工具：错误状态与后备 ChatML 模板。
#include "engine.hpp"

#include <mutex>

namespace llm_provider {

namespace {
std::mutex g_error_mutex;
std::string g_last_error;
}  // namespace

void set_last_error(const std::string& message) {
    std::lock_guard<std::mutex> lock(g_error_mutex);
    g_last_error = message;
}

std::string get_last_error() {
    std::lock_guard<std::mutex> lock(g_error_mutex);
    return g_last_error;
}

std::string build_chatml_prompt(const std::vector<ChatMessage>& messages,
                                const std::string& raw_prompt) {
    if (messages.empty()) return raw_prompt;
    std::string out;
    for (const auto& m : messages) {
        out += "<|im_start|>" + m.role + "\n" + m.content + "<|im_end|>\n";
    }
    out += "<|im_start|>assistant\n";
    return out;
}

}  // namespace llm_provider
