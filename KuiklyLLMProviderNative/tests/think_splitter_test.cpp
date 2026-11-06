// ThinkSplitter 宿主侧单元测试：覆盖标签与 UTF-8 被切开、思考块再次开启、
// 流结束缺少 </think> 等边界。

#include "think_splitter.hpp"

#include <cstdio>
#include <string>

namespace {

int g_failed = 0;

std::string escape(const std::string& s) {
    std::string out;
    for (char c : s) {
        if (c == '\n') out += "\\n";
        else if (c == '\t') out += "\\t";
        else out += c;
    }
    return out;
}

void check(const char* name, const std::string& got, const std::string& want) {
    if (got == want) {
        std::printf("  PASS  %s\n", name);
        return;
    }
    std::printf("  FAIL  %s\n        want=[%s]\n        got =[%s]\n", name,
                escape(want).c_str(), escape(got).c_str());
    ++g_failed;
}

void run_whole(const std::string& input, std::string& reasoning, std::string& content) {
    llm_provider::ThinkSplitter s;
    s.feed(input, reasoning, content);
    s.finish(reasoning, content);
}

/** 每次输入 n 个字节，模拟流式分片。 */
void run_by(const std::string& input, size_t n, std::string& reasoning, std::string& content) {
    llm_provider::ThinkSplitter s;
    for (size_t i = 0; i < input.size(); i += n) {
        s.feed(input.substr(i, n), reasoning, content);
    }
    s.finish(reasoning, content);
}

/**
 * 每个 token 单独 feed，且每次用全新的输出缓冲——与 http_server.cpp 流式回调
 * `std::string reasoning, piece; splitter.feed(token, reasoning, piece);` 一致。
 * out_content 每次都是空的，因此切分器不能靠 out_content.empty() 判断整段正文是否开头。
 */
void run_tokenwise(const std::vector<std::string>& tokens,
                   std::string& reasoning, std::string& content) {
    llm_provider::ThinkSplitter s;
    for (const auto& token : tokens) {
        std::string r, c;
        s.feed(token, r, c);
        reasoning += r;
        content += c;
    }
    std::string r, c;
    s.finish(r, c);
    reasoning += r;
    content += c;
}

}  // namespace

int main() {
    std::string r;
    std::string c;

    std::printf("[1] 完整的思考块 + 正文\n");
    r.clear(); c.clear();
    run_whole("<think>想一下</think>答案", r, c);
    check("reasoning", r, "想一下");
    check("content", c, "答案");

    std::printf("[2] 无思考块，直接是正文\n");
    r.clear(); c.clear();
    run_whole("答案在这里", r, c);
    check("reasoning", r, "");
    check("content", c, "答案在这里");

    std::printf("[3] 思考块没闭合（被截断）\n");
    r.clear(); c.clear();
    run_whole("<think>想到一半", r, c);
    check("reasoning", r, "想到一半");
    check("content", c, "");

    std::printf("[4] </think> 后的换行应被丢弃\n");
    r.clear(); c.clear();
    run_whole("<think>想</think>\n\n答案", r, c);
    check("reasoning", r, "想");
    check("content", c, "答案");

    std::printf("[5] 思考预算耗尽后再次开启思考块\n");
    r.clear(); c.clear();
    run_whole("<think>甲</think>乙<think>丙</think>丁", r, c);
    check("reasoning", r, "甲丙");
    check("content", c, "乙丁");

    std::printf("[6] 正文中出现孤立 </think> 标签时，标签本身不应出现在 content\n");
    r.clear(); c.clear();
    run_whole("<think>甲</think>乙</think>丙", r, c);
    check("reasoning", r, "甲");
    check("content", c, "乙丙");

    std::printf("[7] 逐字节输入：标签与 UTF-8 都会被切开\n");
    for (size_t step = 1; step <= 3; ++step) {
        r.clear(); c.clear();
        const std::string in = "<think>想🎨一下</think>答案😊完毕";
        run_by(in, step, r, c);
        const std::string rname = "step=" + std::to_string(step) + " reasoning";
        const std::string cname = "step=" + std::to_string(step) + " content";
        check(rname.c_str(), r, "想🎨一下");
        check(cname.c_str(), c, "答案😊完毕");
    }

    std::printf("[8] 开头空白 + 思考块（模型常先输出一个换行）\n");
    r.clear(); c.clear();
    run_whole("\n<think>想</think>\n答案", r, c);
    check("reasoning", r, "想");
    check("content", c, "答案");

    std::printf("[9] 空输入\n");
    r.clear(); c.clear();
    run_whole("", r, c);
    check("reasoning", r, "");
    check("content", c, "");

    std::printf("[10] 逐 token 输入：词间前导空格必须保留\n");
    r.clear(); c.clear();
    run_tokenwise({"Running", " an", " LLM", " on", " a", " phone", " works", " offline"}, r, c);
    check("reasoning", r, "");
    check("content", c, "Running an LLM on a phone works offline");

    std::printf("[11] 逐 token + 思考块：闭合后的换行裁掉，正文词间空格保留\n");
    r.clear(); c.clear();
    run_tokenwise({"<think>", "想", "一下", "</think>", "\n\n", "Running", " an", " LLM"}, r, c);
    check("reasoning", r, "想一下");
    check("content", c, "Running an LLM");

    if (g_failed == 0) {
        std::printf("\n全部通过\n");
        return 0;
    }
    std::printf("\n失败 %d 项\n", g_failed);
    return 1;
}
