#include "http_server.hpp"

#include "engine.hpp"
#include "mini_json.hpp"
#include "think_splitter.hpp"

#include <algorithm>
#include <arpa/inet.h>
#include <array>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <functional>
#include <memory>
#include <mutex>
#include <netinet/in.h>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/time.h>
#include <thread>
#include <unistd.h>
#include <utility>
#include <vector>

namespace llm_provider {
namespace {

// ---- 请求限制常量 ----
constexpr int kMaxHeaderBytes = 64 * 1024;
constexpr size_t kMaxBodyBytes = 4u * 1024 * 1024;  // 请求体上限，超限 413
constexpr int kMaxConnections = 16;                 // 有界并发连接数
constexpr int kIoTimeoutSec = 15;                   // 半请求 / 慢客户端回收
constexpr int kGenerateTimeoutSec = 300;            // 单次生成上限

// ---- SIGPIPE 防护（按平台适配） ----
// Linux / Android：send(..., MSG_NOSIGNAL)；Apple：SO_NOSIGPIPE。
// 两者都不存在的平台，在进程级忽略 SIGPIPE。不写死单一平台。
int platform_send_flags() {
#ifdef MSG_NOSIGNAL
    return MSG_NOSIGNAL;
#else
    return 0;
#endif
}

void disable_sigpipe_on_socket(int fd) {
#ifdef SO_NOSIGPIPE
    int v = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &v, sizeof(v));
#else
    (void)fd;
#endif
}

void ensure_no_sigpipe() {
#if !defined(MSG_NOSIGNAL) && !defined(SO_NOSIGPIPE)
    static std::once_flag once;
    std::call_once(once, [] { std::signal(SIGPIPE, SIG_IGN); });
#endif
}

void set_io_timeouts(int fd) {
    timeval tv{};
    tv.tv_sec = kIoTimeoutSec;
    tv.tv_usec = 0;
    ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

std::string lower(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

std::string trim(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) ++a;
    while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) --b;
    return s.substr(a, b - a);
}

/**
 * 从系统 CSPRNG 取 16 字节（128 bit）。std::random_device 不保证非确定性，
 * 因此这里显式使用平台熵源；取不到就直接抛异常，绝不退化到可预测值。
 */
std::array<unsigned char, 16> system_random_16bytes() {
    std::array<unsigned char, 16> out{};
#if defined(__APPLE__)
    arc4random_buf(out.data(), out.size());  // libc，无需链接额外 framework
#else
    const int fd = ::open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        set_last_error("open /dev/urandom failed");
        throw std::runtime_error("no system entropy");
    }
    size_t done = 0;
    while (done < out.size()) {
        const ssize_t n = ::read(fd, out.data() + done, out.size() - done);
        if (n > 0) { done += static_cast<size_t>(n); continue; }
        if (n < 0 && errno == EINTR) continue;
        ::close(fd);
        set_last_error("read /dev/urandom failed");
        throw std::runtime_error("no system entropy");
    }
    ::close(fd);
#endif
    return out;
}

/** base64url 编码，无 '=' padding；字母表只含字母数字与 '-' '_'，可直接放进 Bearer 头。 */
std::string base64url_no_padding(const unsigned char* data, size_t n) {
    static const char* kAlphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    std::string out;
    out.reserve((n * 4 + 2) / 3);
    size_t i = 0;
    for (; i + 3 <= n; i += 3) {
        const uint32_t v = (static_cast<uint32_t>(data[i]) << 16) |
                           (static_cast<uint32_t>(data[i + 1]) << 8) |
                           static_cast<uint32_t>(data[i + 2]);
        out.push_back(kAlphabet[(v >> 18) & 0x3F]);
        out.push_back(kAlphabet[(v >> 12) & 0x3F]);
        out.push_back(kAlphabet[(v >> 6) & 0x3F]);
        out.push_back(kAlphabet[v & 0x3F]);
    }
    const size_t rem = n - i;
    if (rem == 1) {
        const uint32_t v = static_cast<uint32_t>(data[i]) << 16;
        out.push_back(kAlphabet[(v >> 18) & 0x3F]);
        out.push_back(kAlphabet[(v >> 12) & 0x3F]);
    } else if (rem == 2) {
        const uint32_t v = (static_cast<uint32_t>(data[i]) << 16) |
                           (static_cast<uint32_t>(data[i + 1]) << 8);
        out.push_back(kAlphabet[(v >> 18) & 0x3F]);
        out.push_back(kAlphabet[(v >> 12) & 0x3F]);
        out.push_back(kAlphabet[(v >> 6) & 0x3F]);
    }
    return out;
}

/** 生成 `kuikly-<22 字符>` 形式的 API Key（128 bit 系统熵，总长 29 字符）。 */
std::string generate_api_key() {
    const std::array<unsigned char, 16> bytes = system_random_16bytes();
    return "kuikly-" + base64url_no_padding(bytes.data(), bytes.size());
}

/**
 * 定长比较：长度本身不是秘密（key 固定 29 字符），长度不等可提前
 * 返回而不泄露 key 内容；长度相等时比较全部字节、不提前返回，避免逐字节时序差异。
 */
bool secret_equals(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) return false;
    unsigned char diff = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        diff |= static_cast<unsigned char>(a[i] ^ b[i]);
    }
    return diff == 0;
}

/** 从 `Authorization: Bearer <key>` 里取出 key；不符合该格式返回空串。 */
std::string bearer_token(const std::string& header) {
    const std::string prefix = "bearer ";
    const std::string h = trim(header);
    if (h.size() <= prefix.size()) return "";
    if (lower(h.substr(0, prefix.size())) != prefix) return "";
    return trim(h.substr(prefix.size()));  // 尾部也 trim
}

// 所有 send 走这里，平台 flags 防 SIGPIPE；返回值必须被调用方检查。
bool send_all(int fd, const std::string& data) {
    size_t sent = 0;
    const int flags = platform_send_flags();
    while (sent < data.size()) {
        const ssize_t n = ::send(fd, data.data() + sent, data.size() - sent, flags);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        sent += static_cast<size_t>(n);
    }
    return true;
}

// catch 内专用的不抛异常发送，直接对常量缓冲调用 ::send，不构造 std::string。
void send_noexcept(int fd, const char* data, size_t len) noexcept {
    size_t sent = 0;
    const int flags = platform_send_flags();
    while (sent < len) {
        const ssize_t n = ::send(fd, data + sent, len - sent, flags);
        if (n < 0) {
            if (errno == EINTR) continue;
            return;
        }
        if (n == 0) return;
        sent += static_cast<size_t>(n);
    }
}

// Host 白名单，仅回环字面量；缺省或域名（含 DNS rebinding）一律拒绝。
bool host_is_loopback(const std::string& host) {
    std::string h = lower(trim(host));
    if (h.empty()) return false;
    if (h == "::1" || h == "0:0:0:0:0:0:0:1") return true;
    if (h[0] == '[') {  // [::1] 或 [::1]:port
        const size_t rb = h.find(']');
        if (rb == std::string::npos) return false;
        const std::string ip = h.substr(1, rb - 1);
        return ip == "::1" || ip == "0:0:0:0:0:0:0:1";
    }
    const size_t colon = h.find(':');
    if (colon != std::string::npos) h = h.substr(0, colon);  // 去端口
    return h == "127.0.0.1" || h == "localhost";
}

// Origin 只允许本地回环 http(s) 来源；无 Origin（原生 App / curl）放行。
bool origin_is_local(const std::string& origin) {
    const std::string o = lower(trim(origin));
    if (o.empty()) return true;
    std::string rest;
    if (o.compare(0, 7, "http://") == 0) rest = o.substr(7);
    else if (o.compare(0, 8, "https://") == 0) rest = o.substr(8);
    else return false;
    const size_t slash = rest.find('/');
    const std::string authority = (slash == std::string::npos) ? rest : rest.substr(0, slash);
    return host_is_loopback(authority);
}

struct Request {
    std::string method;
    std::string path;
    std::string body;
    std::string authorization;
    std::string host;
    std::string origin;
    bool expect_continue = false;
};

/**
 * 解析一个 HTTP/1.1 请求。
 * 返回：0 = 成功；>0 = 需回该 HTTP 错误码（400/413/501）；<0 = I/O 失败/超时，
 * 直接关闭连接。所有长度/语法校验在此完成。
 */
int read_request(int fd, Request& out) {
    std::string head;
    head.reserve(2048);  // 合理初始 reserve
    char ch;
    int matched = 0;
    const std::string terminator = "\r\n\r\n";
    while (static_cast<int>(head.size()) < kMaxHeaderBytes) {
        const ssize_t n = ::recv(fd, &ch, 1, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;  // 超时 / 错误（SO_RCVTIMEO 下也会走到这里）
        }
        if (n == 0) return -1;  // 半请求头连接关闭
        head += ch;
        if (ch == terminator[static_cast<size_t>(matched)]) {
            if (++matched == 4) break;
        } else {
            matched = (ch == '\r') ? 1 : 0;
        }
    }
    if (matched != 4) return -1;  // 请求头超限或未接收完整

    std::vector<std::string> lines;
    size_t start = 0;
    while (start < head.size()) {
        const size_t end = head.find("\r\n", start);
        if (end == std::string::npos) break;
        lines.push_back(head.substr(start, end - start));
        start = end + 2;
    }
    if (lines.empty()) return 400;

    // 请求行：p2==npos 时 path 取剩余全部
    const size_t p1 = lines[0].find(' ');
    if (p1 == std::string::npos) return 400;
    const size_t p2 = lines[0].find(' ', p1 + 1);
    out.method = trim(lines[0].substr(0, p1));
    out.path = (p2 == std::string::npos)
                   ? trim(lines[0].substr(p1 + 1))
                   : trim(lines[0].substr(p1 + 1, p2 - p1 - 1));
    const size_t q = out.path.find('?');
    if (q != std::string::npos) out.path = out.path.substr(0, q);
    if (out.method.empty() || out.path.empty() || out.path[0] != '/') return 400;

    bool have_cl = false;
    long long content_length = 0;
    for (size_t i = 1; i < lines.size(); ++i) {
        const size_t colon = lines[i].find(':');
        if (colon == std::string::npos) continue;
        const std::string name = lower(trim(lines[i].substr(0, colon)));
        const std::string value = trim(lines[i].substr(colon + 1));  // 完整 trim
        if (name == "content-length") {
            if (have_cl) return 400;  // 重复/冲突长度头
            have_cl = true;
            if (value.empty()) return 400;
            for (char c : value) {
                if (c < '0' || c > '9') return 400;  // 仅 1*DIGIT
            }
            errno = 0;
            char* end = nullptr;
            const long long v = std::strtoll(value.c_str(), &end, 10);
            if (errno == ERANGE || end != value.c_str() + value.size() || v < 0) return 400;
            if (static_cast<unsigned long long>(v) >
                static_cast<unsigned long long>(kMaxBodyBytes)) return 413;  // N12
            content_length = v;
        } else if (name == "transfer-encoding") {
            if (lower(value).find("chunked") != std::string::npos) return 501;  // N17
        } else if (name == "expect") {
            if (lower(value) == "100-continue") out.expect_continue = true;
        } else if (name == "authorization") {
            out.authorization = value;
        } else if (name == "host") {
            out.host = value;
        } else if (name == "origin") {
            out.origin = value;
        }
    }

    // 明确响应 100 Continue，避免客户端等 100 才发 body 造成死锁。
    if (out.expect_continue && content_length > 0) {
        static const char k100[] = "HTTP/1.1 100 Continue\r\n\r\n";
        send_noexcept(fd, k100, sizeof(k100) - 1);
    }

    if (content_length > 0) {
        std::string body;
        body.reserve(static_cast<size_t>(content_length));
        std::vector<char> buf(4096);
        long long remaining = content_length;
        while (remaining > 0) {
            const size_t want = static_cast<size_t>(
                std::min<long long>(remaining, static_cast<long long>(buf.size())));
            const ssize_t n = ::recv(fd, buf.data(), want, 0);
            if (n < 0) {
                if (errno == EINTR) continue;
                return -1;
            }
            if (n == 0) return 400;  // body 被截断不能当成功
            body.append(buf.data(), static_cast<size_t>(n));
            remaining -= static_cast<long long>(n);
        }
        out.body = std::move(body);
    }
    return 0;
}

// 不输出通配的 Access-Control-Allow-* 响应头；本地同源无需 CORS，跨源请求由
// Host/Origin 策略与浏览器同源策略共同拦截。
bool write_status(int fd, int status, const Json& body) {
    const std::string bytes = body.dump();
    const char* reason = "Bad Request";
    std::string extra;
    switch (status) {
        case 200: reason = "OK"; break;
        case 400: reason = "Bad Request"; break;
        case 401: reason = "Unauthorized"; extra = "WWW-Authenticate: Bearer\r\n"; break;
        case 403: reason = "Forbidden"; break;
        case 404: reason = "Not Found"; break;
        case 413: reason = "Payload Too Large"; break;
        case 500: reason = "Internal Server Error"; break;
        case 501: reason = "Not Implemented"; break;
        default:  reason = "Error"; break;
    }
    const std::string head =
        "HTTP/1.1 " + std::to_string(status) + " " + reason + "\r\n"
        "Content-Type: application/json; charset=utf-8\r\n"
        "Content-Length: " + std::to_string(bytes.size()) + "\r\n" +
        extra +
        "Connection: close\r\n\r\n";
    return send_all(fd, head + bytes);  // 返回值被返回（检查）
}

// catch 内 / read_request 错误路径用的不抛异常最小响应（只发状态行）。
void send_status_noexcept(int fd, int status) noexcept {
    const char* reason = "Bad Request";
    switch (status) {
        case 400: reason = "Bad Request"; break;
        case 403: reason = "Forbidden"; break;
        case 413: reason = "Payload Too Large"; break;
        case 500: reason = "Internal Server Error"; break;
        case 501: reason = "Not Implemented"; break;
        default:  reason = "Error"; break;
    }
    char buf[160];
    const int n = std::snprintf(buf, sizeof(buf),
        "HTTP/1.1 %d %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        status, reason);
    if (n > 0) send_noexcept(fd, buf, static_cast<size_t>(n));
}

Json error_body(const std::string& message, const std::string& type) {
    Json err = Json::make_object();
    err.set("message", Json::make_string(message));
    err.set("type", Json::make_string(type));
    Json root = Json::make_object();
    root.set("error", err);
    return root;
}

constexpr const char* kNoModelMessage = "no model is active; download and select a model first";

/**
 * 生成失败且尚未向客户端写出任何字节时，按失败类型回 JSON 错误：
 * 未加载模型 / 超出上下文是请求方问题（400），引擎内部失败是服务端问题（500）。
 */
void write_generate_error(int fd, GenerateError error) {
    if (error == GenerateError::NoModel) {
        (void)write_status(fd, 400, error_body(kNoModelMessage, "invalid_request_error"));
        return;
    }
    const std::string detail = get_last_error();
    if (error == GenerateError::ContextOverflow) {
        (void)write_status(fd, 400, error_body(
            detail.empty() ? "prompt exceeds the context window" : detail, "invalid_request_error"));
        return;
    }
    (void)write_status(fd, 500, error_body(detail.empty() ? "generation failed" : detail, "server_error"));
}

/**
 * 解析 messages。content 支持 OpenAI 的两种形态：字符串，或 content part 数组
 * （文本段按 "\n" 拼接）。非文本段（如 image_url）与其它类型返回 false 并写 error，
 * 由调用方回 400；绝不静默丢弃内容。
 */
bool extract_messages(const Json& body, std::vector<ChatMessage>& out, std::string& error) {
    const Json* messages = body.find("messages");
    if (messages == nullptr || !messages->is_array()) return true;
    for (const Json& item : messages->array) {
        const Json* content = item.find("content");
        std::string text;
        if (content == nullptr || content->is_null()) {
            // 缺省 / null 视为空串（如仅含 tool_calls 的 assistant 消息）。
        } else if (content->is_string()) {
            text = content->string;
        } else if (content->is_array()) {
            bool first = true;
            for (const Json& part : content->array) {
                const std::string type = part.str("type", "");
                const Json* part_text = part.find("text");
                if (type != "text" || part_text == nullptr || !part_text->is_string()) {
                    error = "unsupported content part type: " + (type.empty() ? "(missing)" : type);
                    return false;
                }
                if (!first) text += "\n";
                text += part_text->string;
                first = false;
            }
        } else {
            error = "message content must be a string or an array of text parts";
            return false;
        }
        out.push_back(ChatMessage{item.str("role", "user"), text});
    }
    return true;
}

/**
 * 非阻塞探测对端是否已关闭（非流式请求在生成期间不写 socket，send 无法发现断开）。
 * recv 返回 0 = 对端 FIN；有数据可读（pipelining）不视为断开。
 */
bool peer_closed(int fd) {
    char c;
    const ssize_t n = ::recv(fd, &c, 1, MSG_PEEK | MSG_DONTWAIT);
    if (n == 0) return true;
    if (n < 0) return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR;
    return false;
}

// 非流式生成期间每隔多少个 token 探测一次断开。
constexpr int kPeerCheckInterval = 16;

// 思考预算默认值：模型完成一段较短思考后即转入正文，将剩余 token 留给答案。
constexpr int kDefaultReasoningBudget = 192;

}  // namespace

struct HttpServer::Impl {
    const int requested_port;  // 0 = 由内核分配；每次 start() 都按它重新 bind
    int bound_port = 0;        // start() 成功后的实际端口（getsockname），stop() 后归零
    const int n_ctx;
    const int n_threads;
    const double default_temperature;

    std::atomic<int> listen_fd{-1};              // atomic 消除 accept/stop 竞态
    std::atomic<bool> running{false};
    std::atomic<bool> cancel_generation{false};  // stop 时触发在途生成退出
    std::thread accept_thread;

    // engine_mutex 串行化 close / generate / load_model 换入。
    // 初始即为未加载模型的 llama.cpp 引擎；没有模拟引擎可供退化。
    mutable std::mutex engine_mutex;
    std::shared_ptr<Engine> engine;
    std::string model_id;  // 与 engine 同受 engine_mutex 保护

    // 连接线程共享所有权 + 活跃计数 + 等待，禁止 detach。
    struct ConnSlot {
        std::thread thread;
        std::shared_ptr<std::atomic<bool>> done;
        int fd;  // 活跃连接 socket：stop 时主动 shutdown，快速唤醒阻塞的 recv/send
    };
    std::mutex conn_mutex;                  // 保护 conn_slots；也作 conn_cv 的锁
    std::condition_variable conn_cv;
    std::vector<ConnSlot> conn_slots;
    std::atomic<int> active_connections{0};

    std::atomic<long long> counter{0};
    const std::string api_key;  // 生命周期内不变

    Impl(int p, int ctx, int threads, double temp, const std::string& key)
        : requested_port(p), n_ctx(ctx), n_threads(threads), default_temperature(temp),
          engine(create_llama_engine(ctx, threads)),
          api_key(key.empty() ? generate_api_key() : key) {}

    // 未绑定（未启动 / 已 stop）时没有有效地址，返回空串。
    std::string base_url() const {
        return bound_port > 0 ? "http://127.0.0.1:" + std::to_string(bound_port) : "";
    }

    struct EngineInfo {
        std::string name;
        bool loaded;
        std::string model_id;
    };
    // 一次加锁取全，避免在 generate 持锁期间二次加锁（engine_mutex 非递归）。
    EngineInfo engine_info() const {
        std::lock_guard<std::mutex> lock(engine_mutex);
        return EngineInfo{engine->name(), engine->model_loaded(), model_id};
    }
    // generate 与 close 共用 engine_mutex，杜绝 llama_free(ctx) 与
    // llama_decode 并发 UAF。约定 sink 内不得再次获取 engine_mutex。
    GenerateResult generate_current(const std::vector<ChatMessage>& messages,
                                    const std::string& raw_prompt,
                                    const GenerateOptions& options,
                                    const TokenSink& sink) {
        std::lock_guard<std::mutex> lock(engine_mutex);
        return engine->generate(messages, raw_prompt, options, sink);
    }
    std::string new_id() {
        return "chatcmpl-" + std::to_string(static_cast<long long>(std::time(nullptr))) +
               "-" + std::to_string(++counter);
    }

    // 回收已结束的连接线程，避免 conn_slots 无限增长。join 在锁外进行，
    // 与 worker 结尾拿 conn_mutex 不死锁。
    void reap_finished() {
        std::vector<std::thread> finished;
        {
            std::lock_guard<std::mutex> lk(conn_mutex);
            for (auto it = conn_slots.begin(); it != conn_slots.end();) {
                if (it->done->load()) {
                    finished.push_back(std::move(it->thread));
                    it = conn_slots.erase(it);
                } else {
                    ++it;
                }
            }
        }
        for (auto& t : finished) {
            if (t.joinable()) t.join();
        }
    }

    Json models_response() const {
        const EngineInfo info = engine_info();
        Json data = Json::make_array();
        if (info.loaded && !info.model_id.empty()) {
            Json item = Json::make_object();
            item.set("id", Json::make_string(info.model_id));
            item.set("object", Json::make_string("model"));
            item.set("created", Json::make_number(static_cast<double>(std::time(nullptr))));
            item.set("owned_by", Json::make_string("local"));
            data.push(item);
        }
        Json root = Json::make_object();
        root.set("object", Json::make_string("list"));
        root.set("data", data);
        return root;
    }

    // model 由调用方一次性快照后传入，避免 generate 持锁期间二次加锁。
    Json chunk_response(const std::string& id, const std::string& object_type,
                        const std::string& model, bool chat, const std::string& delta,
                        const std::string& finish_reason,
                        const std::string& reasoning = "") const {
        Json choice = Json::make_object();
        choice.set("index", Json::make_number(0));
        if (delta.empty() && reasoning.empty()) {
            choice.set("delta", Json::make_object());
        } else if (!chat) {
            Json d = Json::make_object();
            d.set("text", Json::make_string(delta));
            choice.set("delta", d);
        } else {
            Json d = Json::make_object();
            if (!reasoning.empty()) d.set("reasoning_content", Json::make_string(reasoning));
            if (!delta.empty()) d.set("content", Json::make_string(delta));
            choice.set("delta", d);
        }
        if (finish_reason.empty()) choice.set("finish_reason", Json::make_null());
        else choice.set("finish_reason", Json::make_string(finish_reason));
        Json choices = Json::make_array();
        choices.push(choice);
        Json root = Json::make_object();
        root.set("id", Json::make_string(id));
        root.set("object", Json::make_string(object_type));
        root.set("created", Json::make_number(static_cast<double>(std::time(nullptr))));
        root.set("model", Json::make_string(model));
        root.set("choices", choices);
        return root;
    }

    void handle_completion(int fd, const std::string& raw_body, bool chat,
                           bool& sse_started, const std::atomic<bool>* cancel) {
        Json body;
        try {
            body = Json::parse(raw_body.empty() ? "{}" : raw_body);
        } catch (...) {
            // 深层嵌套 / 非法语法统一 400。
            (void)write_status(fd, 400, error_body("invalid JSON body", "invalid_request_error"));
            return;
        }
        const EngineInfo info = engine_info();
        if (!info.loaded) {  // 未加载模型时拒绝请求，不隐式加载或切换模型
            (void)write_status(fd, 400, error_body(kNoModelMessage, "invalid_request_error"));
            return;
        }
        const std::string& mid = info.model_id;
        const std::string requested_model = body.str("model", "");
        if (!requested_model.empty() && requested_model != mid) {
            (void)write_status(fd, 400,
                error_body("model not active: " + requested_model + " (select it first)",
                           "invalid_request_error"));
            return;
        }
        const bool stream = body.flag("stream", false);
        const std::string raw_prompt = body.str("prompt", "");
        std::vector<ChatMessage> messages;
        std::string messages_error;
        if (!extract_messages(body, messages, messages_error)) {
            (void)write_status(fd, 400, error_body(messages_error, "invalid_request_error"));
            return;
        }

        GenerateOptions options;
        options.max_tokens = std::min(std::max(body.integer("max_tokens", 1024), 1), 4096);
        options.temperature = static_cast<float>(body.real("temperature", default_temperature));
        int budget = body.integer("reasoning_budget", kDefaultReasoningBudget);
        if (!body.flag("enable_thinking", true)) budget = 0;
        options.reasoning_budget = std::min(std::max(budget, -1), 4096);
        options.cancel = cancel;  // stop / 断连触发
        options.deadline = std::chrono::steady_clock::now() +
                           std::chrono::seconds(kGenerateTimeoutSec);

        const std::string id = new_id();
        const std::string object_type = chat ? "chat.completion" : "text_completion";

        if (!stream) {
            std::string raw_text;
            int pieces = 0;
            bool client_gone = false;
            const GenerateResult res = generate_current(
                messages, raw_prompt, options,
                [&](const std::string& token) -> bool {
                    raw_text += token;
                    // 非流式期间不写 socket，需主动探测断开，否则会一直占用引擎锁直到生成结束。
                    if (++pieces % kPeerCheckInterval == 0 && peer_closed(fd)) {
                        client_gone = true;
                        return false;
                    }
                    return true;
                });
            if (client_gone) return;
            if (res.error != GenerateError::None) {
                write_generate_error(fd, res.error);
                return;
            }
            ThinkSplitter splitter;
            std::string reasoning, text;
            splitter.feed(raw_text, reasoning, text);
            splitter.finish(reasoning, text);
            Json choice = Json::make_object();
            choice.set("index", Json::make_number(0));
            if (chat) {
                Json message = Json::make_object();
                message.set("role", Json::make_string("assistant"));
                message.set("content", Json::make_string(text));
                if (!reasoning.empty()) message.set("reasoning_content", Json::make_string(reasoning));
                choice.set("message", message);
            } else {
                choice.set("text", Json::make_string(text));
            }
            choice.set("finish_reason", Json::make_string(res.finish_reason));
            Json choices = Json::make_array();
            choices.push(choice);
            Json usage = Json::make_object();
            usage.set("prompt_tokens", Json::make_number(res.prompt_tokens));
            usage.set("completion_tokens", Json::make_number(res.completion_tokens));
            usage.set("total_tokens", Json::make_number(res.prompt_tokens + res.completion_tokens));
            Json root = Json::make_object();
            root.set("id", Json::make_string(id));
            root.set("object", Json::make_string(object_type));
            root.set("created", Json::make_number(static_cast<double>(std::time(nullptr))));
            root.set("model", Json::make_string(mid));
            root.set("choices", choices);
            root.set("usage", usage);
            (void)write_status(fd, 200, root);
            return;
        }

        // SSE 头延迟到首个输出片段（或生成正常结束）时才发送：prompt 阶段的失败
        // （超出上下文、decode 失败）此时尚未写出任何字节，仍可回 JSON 错误与正确状态码。
        // SSE 头发出后才置 sse_started；此后异常不叠发 JSON。
        const std::string sse_headers =
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: text/event-stream; charset=utf-8\r\n"
            "Cache-Control: no-cache\r\n"
            "Connection: close\r\n\r\n";
        bool client_gone = false;
        auto ensure_headers = [&]() -> bool {
            if (sse_started) return true;
            if (!send_all(fd, sse_headers)) {  // 发头失败即终止
                client_gone = true;
                return false;
            }
            sse_started = true;
            return true;
        };

        const std::string chunk_object = chat ? "chat.completion.chunk" : "text_completion";
        ThinkSplitter splitter;
        auto emit = [&](const std::string& reasoning, const std::string& piece) -> bool {
            if (reasoning.empty() && piece.empty()) return true;
            if (!ensure_headers()) return false;
            const Json chunk = chunk_response(id, chunk_object, mid, chat, piece, "", reasoning);
            if (!send_all(fd, "data: " + chunk.dump() + "\n\n")) {
                client_gone = true;
                return false;  // send 失败 → sink 返回 false → 生成立即停止
            }
            return true;
        };
        const GenerateResult res = generate_current(
            messages, raw_prompt, options,
            [&](const std::string& token) -> bool {
                std::string reasoning, piece;
                splitter.feed(token, reasoning, piece);
                return emit(reasoning, piece);
            });
        if (client_gone) return;  // 断连直接关连接，不补 done/[DONE]
        if (!sse_started && res.error != GenerateError::None) {
            write_generate_error(fd, res.error);
            return;
        }
        // 生成中途失败（已开始输出）只能在流内以 finish_reason="error" 结束。
        if (!ensure_headers()) return;
        {
            std::string reasoning, piece;
            splitter.finish(reasoning, piece);
            if (!emit(reasoning, piece)) return;
        }
        const Json done = chunk_response(id, chunk_object, mid, chat, "", res.finish_reason);
        if (!send_all(fd, "data: " + done.dump() + "\n\n")) return;
        const Json* stream_options = body.find("stream_options");
        if (stream_options && stream_options->is_object() &&
            stream_options->flag("include_usage", false)) {
            Json usage = Json::make_object();
            usage.set("prompt_tokens", Json::make_number(res.prompt_tokens));
            usage.set("completion_tokens", Json::make_number(res.completion_tokens));
            usage.set("total_tokens", Json::make_number(res.prompt_tokens + res.completion_tokens));
            Json tail = Json::make_object();
            tail.set("id", Json::make_string(id));
            tail.set("object", Json::make_string(chunk_object));
            tail.set("created", Json::make_number(static_cast<double>(std::time(nullptr))));
            tail.set("model", Json::make_string(mid));
            tail.set("choices", Json::make_array());
            tail.set("usage", usage);
            if (!send_all(fd, "data: " + tail.dump() + "\n\n")) return;
        }
        if (!send_all(fd, "data: [DONE]\n\n")) return;
    }

    // fd 由调用方（连接 worker）在 conn_mutex 内关闭，见 HttpServer::start。
    void handle(int fd) {
        disable_sigpipe_on_socket(fd);
        set_io_timeouts(fd);  // recv/send 超时

        Request request;
        int rc = 0;
        try {
            rc = read_request(fd, request);
        } catch (...) {
            return;  // 解析期异常：直接关连接
        }
        if (rc != 0) {
            if (rc > 0) send_status_noexcept(fd, rc);  // 400/413/501 等
            return;
        }

        bool sse_started = false;
        try {
            // 所有请求（含 OPTIONS）先验 Host/Origin，防 DNS rebinding / 跨源。
            if (!host_is_loopback(request.host) || !origin_is_local(request.origin)) {
                (void)write_status(fd, 403,
                    error_body("Forbidden: Host/Origin not allowed", "invalid_request_error"));
                return;
            }
            // OPTIONS 预检免 Bearer，但仍受上面的 Host/Origin 策略约束；不回 CORS 头。
            if (request.method == "OPTIONS") {
                (void)write_status(fd, 200, Json::make_object());
                return;
            }
            // 其余所有端点都要求 `Authorization: Bearer <api_key>`。
            if (!secret_equals(bearer_token(request.authorization), api_key)) {
                (void)write_status(fd, 401,
                    error_body("Incorrect API key provided", "invalid_request_error"));
                return;
            }
            if (request.method == "GET" && request.path == "/health") {
                const EngineInfo info = engine_info();
                Json health = Json::make_object();
                health.set("status", Json::make_string("ok"));
                health.set("engine", Json::make_string(info.name));
                health.set("model_loaded", Json::make_bool(info.loaded));
                (void)write_status(fd, 200, health);
            } else if (request.method == "GET" && request.path == "/v1/models") {
                (void)write_status(fd, 200, models_response());
            } else if (request.method == "POST" && request.path == "/v1/chat/completions") {
                handle_completion(fd, request.body, true, sse_started, &cancel_generation);
            } else if (request.method == "POST" && request.path == "/v1/completions") {
                handle_completion(fd, request.body, false, sse_started, &cancel_generation);
            } else {
                (void)write_status(fd, 404,
                    error_body("Not Found: " + request.path, "invalid_request_error"));
            }
        } catch (...) {
            // catch 内不抛异常（不构造 Json / std::string，只用 noexcept 最小响应）；
            // SSE 已建立则直接关连接，绝不叠发 500 JSON 污染事件流。
            if (!sse_started) send_status_noexcept(fd, 500);
        }
    }
};

HttpServer::HttpServer(int port, int n_ctx, int n_threads, double default_temperature,
                       const std::string& api_key)
    : impl_(std::make_shared<Impl>(port, n_ctx, n_threads, default_temperature, api_key)) {}

HttpServer::~HttpServer() { stop(); }

bool HttpServer::start() {
    if (impl_->running.load()) return true;
    // 0 表示由内核分配随机端口；避免 >65535 被静默截断后与 base_url() 不一致。
    if (impl_->requested_port < 0 || impl_->requested_port > 65535) {
        set_last_error("invalid port (0..65535, 0 = auto): " + std::to_string(impl_->requested_port));
        return false;
    }
    ensure_no_sigpipe();
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        set_last_error("socket() failed");
        return false;
    }
    disable_sigpipe_on_socket(fd);
    int reuse = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(impl_->requested_port));
    addr.sin_addr.s_addr = ::inet_addr("127.0.0.1");  // 仅回环
    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
        ::listen(fd, 16) != 0) {
        ::close(fd);
        set_last_error("bind/listen failed on port " + std::to_string(impl_->requested_port));
        return false;
    }
    // port=0 时取回内核分配的实际端口，base_url() / port() 都以此为唯一来源。
    sockaddr_in bound{};
    socklen_t bound_len = sizeof(bound);
    if (::getsockname(fd, reinterpret_cast<sockaddr*>(&bound), &bound_len) != 0) {
        ::close(fd);
        set_last_error("getsockname() failed");
        return false;
    }
    impl_->bound_port = ntohs(bound.sin_port);
    impl_->listen_fd.store(fd);
    impl_->cancel_generation.store(false);  // 复位，供本生命周期使用
    impl_->running.store(true);
    {
        std::lock_guard<std::mutex> lk(impl_->conn_mutex);
        impl_->conn_slots.reserve(static_cast<size_t>(kMaxConnections) * 2);
    }

    // accept 线程与每个连接线程都捕获 shared_ptr<Impl>，Impl 保活到全部
    // 线程 join 结束；彻底禁止 detach。
    auto self = impl_;
    impl_->accept_thread = std::thread([self]() noexcept {
        while (self->running.load()) {
            const int client = ::accept(self->listen_fd.load(), nullptr, nullptr);
            if (client < 0) {
                const int err = errno;
                if (!self->running.load()) break;
                // EMFILE / ENFILE 等持续性错误会让 accept 立即再次失败，退避后重试避免空转占满 CPU。
                if (err != EINTR) std::this_thread::sleep_for(std::chrono::milliseconds(10));
                continue;
            }
            disable_sigpipe_on_socket(client);
            set_io_timeouts(client);
            // 有界并发连接数；超限直接拒绝，不创建线程。
            if (self->active_connections.load() >= kMaxConnections) {
                ::close(client);
                continue;
            }
            self->active_connections.fetch_add(1);
            auto done = std::make_shared<std::atomic<bool>>(false);
            std::thread worker;
            try {
                worker = std::thread([self, client, done]() noexcept {
                    try {
                        self->handle(client);
                    } catch (...) {
                        // handle 内部已捕获异常；此处再保护一次，确保线程函数不抛异常。
                    }
                    {
                        // done 置位与 close 在同一把锁内完成：stop() 持该锁遍历时，
                        // 要么看到 done=false 且 fd 仍有效，要么看到 done=true 并跳过，
                        // 不会 shutdown 一个已被进程内其它模块复用的 fd 号。
                        // active_connections 与 conn_cv.wait 的谓词也在同一锁下修改，避免丢失唤醒。
                        std::lock_guard<std::mutex> lk(self->conn_mutex);
                        done->store(true);
                        ::close(client);
                        self->active_connections.fetch_sub(1);
                    }
                    self->conn_cv.notify_all();
                });
            } catch (...) {
                // 线程创建失败：回收计数并关 fd，不 terminate、不 detach。
                self->active_connections.fetch_sub(1);
                ::close(client);
                continue;
            }
            try {
                std::lock_guard<std::mutex> lk(self->conn_mutex);
                self->conn_slots.push_back(Impl::ConnSlot{std::move(worker), done, client});
            } catch (...) {
                // 极端 OOM：仍 join，绝不留下 joinable 触发 terminate。
                // worker 结束时已自行关闭 fd 并递减 active_connections，这里不重复递减。
                if (worker.joinable()) worker.join();
                continue;
            }
            self->reap_finished();  // 回收已结束线程，控制 conn_slots 规模
        }
    });
    return true;
}

void HttpServer::stop() {
    if (!impl_->running.exchange(false)) return;  // 幂等
    // 先触发取消，让在途 generate 尽快退出，避免持锁期间空等。
    impl_->cancel_generation.store(true);
    const int fd = impl_->listen_fd.exchange(-1);  // atomic 交换
    if (fd >= 0) {
        ::shutdown(fd, SHUT_RDWR);
        ::close(fd);
    }
    impl_->bound_port = 0;  // 监听已关闭，旧地址失效；再次 start() 按 requested_port 重新分配
    if (impl_->accept_thread.joinable()) impl_->accept_thread.join();

    // 主动唤醒仍在 recv/send 上阻塞的在途连接，避免 stop 等待到 kIoTimeoutSec 超时。
    // 监听 socket 已关闭、accept 线程已 join，conn_slots 不会再增长；
    // 只作用于尚未结束的线程，已结束的槽由 reap_finished 回收。
    {
        std::lock_guard<std::mutex> lk(impl_->conn_mutex);
        for (const auto& slot : impl_->conn_slots) {
            if (!slot.done->load()) ::shutdown(slot.fd, SHUT_RDWR);
        }
    }

    // 等待所有在途连接线程结束（recv/send 超时 + cancel 保证不会永久阻塞）。
    {
        std::unique_lock<std::mutex> lk(impl_->conn_mutex);
        impl_->conn_cv.wait(lk, [this] { return impl_->active_connections.load() == 0; });
    }
    // 禁止 detach：把所有连接线程对象 join 掉。
    std::vector<std::thread> threads;
    {
        std::lock_guard<std::mutex> lk(impl_->conn_mutex);
        for (auto& slot : impl_->conn_slots) threads.push_back(std::move(slot.thread));
        impl_->conn_slots.clear();
    }
    for (auto& t : threads) {
        if (t.joinable()) t.join();
    }

    // 此时无并发 generate，close 与 generate 已由 engine_mutex 串行化。
    {
        std::lock_guard<std::mutex> lock(impl_->engine_mutex);
        impl_->engine->close();
    }
    impl_->cancel_generation.store(false);
}

bool HttpServer::running() const { return impl_->running.load(); }

void HttpServer::unload_model() {
    std::lock_guard<std::mutex> lock(impl_->engine_mutex);
    impl_->engine->close();
    // 换回「未加载模型」的 llama.cpp 引擎，推理端点继续由 handle_completion
    // 的 !info.loaded 分支以 400 显式拒绝。
    impl_->engine = std::shared_ptr<Engine>(
        create_llama_engine(impl_->n_ctx, impl_->n_threads));
    impl_->model_id.clear();  // 该写入受 engine_mutex 保护
}

bool HttpServer::load_model(const std::string& model_path, const std::string& model_id) {
    // 先卸后载：新旧两份权重 + KV 同时驻留在移动端容易 OOM（被系统直接杀进程）。
    // 代价：加载期间推理端点以 400 拒绝；加载失败后服务保持「无模型」，
    // 平台层以 llmprovider_model_id() 回填 activeId。
    unload_model();
    // 构造 + 数百 MB 加载在锁外，避免阻塞 getter / 其它请求。
    std::unique_ptr<Engine> candidate = create_llama_engine(impl_->n_ctx, impl_->n_threads);
    if (!candidate) {
        if (get_last_error().empty()) set_last_error("create_llama_engine returned nullptr");
        return false;
    }
    if (!candidate->load(model_path)) {
        if (get_last_error().empty()) set_last_error("engine->load() failed: " + model_path);
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(impl_->engine_mutex);
        // 直接由 unique_ptr 转换为 shared_ptr，消除 release() 所有权缺口。
        impl_->engine = std::shared_ptr<Engine>(std::move(candidate));
        if (!model_id.empty()) impl_->model_id = model_id;  // 成功才写、且在锁内
    }
    return true;
}

std::string HttpServer::base_url() const { return impl_->base_url(); }
int HttpServer::port() const { return impl_->bound_port; }
std::string HttpServer::engine_name() const { return impl_->engine_info().name; }
std::string HttpServer::model_id() const { return impl_->engine_info().model_id; }
std::string HttpServer::api_key() const { return impl_->api_key; }
bool HttpServer::model_loaded() const { return impl_->engine_info().loaded; }

}  // namespace llm_provider
