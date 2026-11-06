// HttpServer 宿主侧单元测试：apiKey 格式（base64url 编码）与 port=0 随机端口生命周期。
// 用 FakeEngine 桩替代 llama.cpp，不链接 llama / ggml。

#include "engine.hpp"
#include "http_server.hpp"

#include <arpa/inet.h>
#include <cstdio>
#include <netinet/in.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>

namespace llm_provider {

class FakeEngine : public Engine {
public:
    std::string name() const override { return "fake"; }
    bool model_loaded() const override { return false; }
    bool load(const std::string&) override { return false; }
    GenerateResult generate(const std::vector<ChatMessage>&, const std::string&,
                            const GenerateOptions&, const TokenSink&) override {
        return {};
    }
    void close() override {}
};

std::unique_ptr<Engine> create_llama_engine(int, int) {
    return std::unique_ptr<Engine>(new FakeEngine());
}

}  // namespace llm_provider

namespace {

int g_failed = 0;

void check(const char* name, bool ok, const std::string& detail = "") {
    if (ok) {
        std::printf("  PASS  %s\n", name);
        return;
    }
    std::printf("  FAIL  %s  %s\n", name, detail.c_str());
    ++g_failed;
}

bool is_base64url(const std::string& s) {
    for (char c : s) {
        const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                        (c >= '0' && c <= '9') || c == '-' || c == '_';
        if (!ok) return false;
    }
    return true;
}

/** 在回环地址监听指定端口，返回 fd；失败返回 -1。用来模拟端口被其它进程占用。 */
int occupy_port(int port) {
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(port));
    addr.sin_addr.s_addr = ::inet_addr("127.0.0.1");
    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
        ::listen(fd, 1) != 0) {
        ::close(fd);
        return -1;
    }
    return fd;
}

bool can_connect(int port) {
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return false;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(port));
    addr.sin_addr.s_addr = ::inet_addr("127.0.0.1");
    const bool ok = ::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0;
    ::close(fd);
    return ok;
}

std::string url_of(int port) { return "http://127.0.0.1:" + std::to_string(port); }

}  // namespace

int main() {
    using llm_provider::HttpServer;

    std::printf("[1] apiKey = kuikly- + 22 字符 base64url（16 字节无 padding）\n");
    {
        HttpServer a(0, 512, 1, 0.7);
        HttpServer b(0, 512, 1, 0.7);
        const std::string key = a.api_key();
        const std::string prefix = "kuikly-";
        check("总长 29", key.size() == 29, key);
        check("前缀 kuikly-", key.compare(0, prefix.size(), prefix) == 0, key);
        check("后缀只含 base64url 字符", is_base64url(key.substr(prefix.size())), key);
        check("两次生成不同", key != b.api_key());
        check("显式传入的 key 原样使用", HttpServer(0, 512, 1, 0.7, "given").api_key() == "given");
    }

    std::printf("[2] port=0：未启动无地址，启动后回填内核分配端口\n");
    {
        HttpServer s(0, 512, 1, 0.7);
        check("启动前 port()==0", s.port() == 0);
        check("启动前 base_url() 为空", s.base_url().empty(), s.base_url());
        check("start 成功", s.start());
        const int port = s.port();
        check("port() 在 1..65535", port > 0 && port <= 65535, std::to_string(port));
        check("base_url() 与 port() 一致", s.base_url() == url_of(port), s.base_url());
        check("实际端口可连接", can_connect(port));
        check("运行中重复 start 幂等、端口不变", s.start() && s.port() == port);
        s.stop();
        check("stop 后 port()==0", s.port() == 0);
        check("stop 后 base_url() 为空", s.base_url().empty(), s.base_url());
    }

    std::printf("[3] 同一实例 stop→start 按 port=0 重新分配，不复用旧端口\n");
    {
        HttpServer s(0, 512, 1, 0.7);
        check("首次 start 成功", s.start());
        const int old_port = s.port();
        s.stop();
        const int blocker = occupy_port(old_port);  // 旧端口被其它进程占用
        check("占住旧端口", blocker >= 0, std::to_string(old_port));
        check("再次 start 成功", s.start(), llm_provider::get_last_error());
        check("新端口 != 旧端口", s.port() > 0 && s.port() != old_port, std::to_string(s.port()));
        check("base_url() 与新端口一致", s.base_url() == url_of(s.port()), s.base_url());
        s.stop();
        if (blocker >= 0) ::close(blocker);
    }

    std::printf("[4] 非法端口\n");
    {
        HttpServer neg(-1, 512, 1, 0.7);
        HttpServer big(65536, 512, 1, 0.7);
        check("port=-1 start 失败", !neg.start());
        check("port=65536 start 失败", !big.start());
        check("失败后 port()==0", neg.port() == 0 && big.port() == 0);
    }

    if (g_failed == 0) {
        std::printf("\n全部通过\n");
        return 0;
    }
    std::printf("\n失败 %d 项\n", g_failed);
    return 1;
}
