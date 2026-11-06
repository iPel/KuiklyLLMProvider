#include "provider_c_api.h"

#include "http_server.hpp"
#include "engine.hpp"

#include <atomic>
#include <exception>
#include <memory>
#include <mutex>
#include <string>

namespace {

struct State {
    // 未启动时为空 / 0：端口由内核分配，没有可预先知道的地址。
    std::string base_url;
    std::string engine_name = "not-started";
    std::string model_id;
    std::string api_key;
    int port = 0;
    int model_loaded = 0;
};

// 写操作串行锁（含耗时加载）。getter 完全不碰它，改读下面的 g_state 快照，
// 因此后台 start 加载数百 MB 模型时，主线程 status 系列 getter 不被阻塞。
std::mutex g_op_mutex;
std::unique_ptr<llm_provider::HttpServer> g_server;  // 受 g_op_mutex 保护
std::atomic<int> g_running{0};                        // is_running 无锁快路径

// getter 读取的轻量快照，临界区只有几次字符串拷贝。
std::mutex g_state_mutex;
State g_state;

// 返回指针使用线程局部缓存，避免多线程数据竞争与
// 「下次调用改写 string 导致指针失效」的问题。
thread_local std::string tls_cache;

const char* cache_copy(const std::string& s) {
    tls_cache = s;
    return tls_cache.c_str();
}

// 调用方必须持 g_op_mutex。读 g_server 的瞬时状态写入快照。
void refresh_state_locked() {
    State snap;
    if (g_server) {
        snap.base_url = g_server->base_url();
        snap.engine_name = g_server->engine_name();
        snap.model_id = g_server->model_id();
        snap.api_key = g_server->api_key();
        snap.model_loaded = g_server->model_loaded() ? 1 : 0;
        snap.port = g_server->port();  // 实际绑定端口（port=0 时为内核分配结果）
    }
    std::lock_guard<std::mutex> lk(g_state_mutex);
    g_state = snap;
}

// 失败/停止时重置全部导出状态。调用方持 g_op_mutex。
void reset_state_locked() {
    g_server.reset();  // ~HttpServer -> stop()，join 全部连接线程，安全
    g_running.store(0);
    std::lock_guard<std::mutex> lk(g_state_mutex);
    g_state = State{};
}

// 启动失败：重置全部导出状态。调用方持 g_op_mutex。
int fail_start_locked() {
    reset_state_locked();
    return 0;
}

// 构造 + 加载 + 启动 + 换入。调用方持 g_op_mutex，入口已清空 last_error，且已确认需要（重新）启动。
int start_locked(int requested_port, const char* model_path, const char* model_id) {
    const std::string id = (model_id != nullptr) ? model_id : "";
    std::unique_ptr<llm_provider::HttpServer> server;
    try {
        server.reset(new llm_provider::HttpServer(requested_port, 4096, 4, 0.7));
    } catch (const std::exception& e) {
        // 构造期子步骤已写入的原因优先保留；否则用异常信息（如取不到熵时的 "no system entropy"）。
        if (llm_provider::get_last_error().empty()) llm_provider::set_last_error(e.what());
        return fail_start_locked();
    }
    // 加载在 g_op_mutex 内，但 getter 走 g_state_mutex，不受影响；load 失败不阻止启动。
    if (model_path != nullptr && *model_path) {
        server->load_model(model_path, id);
    }
    if (!server->start()) {
        llm_provider::set_last_error("HttpServer::start() failed (bind/listen)");
        return fail_start_locked();
    }
    g_server = std::move(server);
    g_running.store(1);
    refresh_state_locked();  // 从 g_server 取实际端口 / base_url / apiKey 快照
    return 1;
}

}  // namespace

extern "C" {

int llmprovider_start(int port, const char *model_path, const char *model_id) {
    try {
        // 0 = 不指定，由内核分配随机端口；负数与 >65535 为非法参数。
        if (port < 0 || port > 65535) {
            llm_provider::set_last_error("invalid port (0..65535, 0 = auto)");
            return 0;
        }
        std::lock_guard<std::mutex> op(g_op_mutex);
        llm_provider::set_last_error("");  // 入口清空陈旧错误
        // 幂等 —— 已在运行时直接刷新状态返回，不重建服务、不轮换端口 / apiKey。
        if (g_server && g_server->running()) {
            refresh_state_locked();
            return 1;
        }
        return start_locked(port, model_path, model_id);
    } catch (...) {
        llm_provider::set_last_error("llmprovider_start: C++ exception");
        return 0;
    }
}

void llmprovider_stop(void) {
    try {
        std::lock_guard<std::mutex> op(g_op_mutex);
        llm_provider::set_last_error("");
        g_server.reset();
        g_running.store(0);
        std::lock_guard<std::mutex> lk(g_state_mutex);
        g_state.engine_name = "not-started";
        g_state.model_loaded = 0;
        g_state.api_key.clear();
        g_state.model_id.clear();
        // 端口是内核分配的，服务销毁后地址已失效，不再保留。
        g_state.base_url.clear();
        g_state.port = 0;
    } catch (...) {
        llm_provider::set_last_error("llmprovider_stop: C++ exception");
    }
}

int llmprovider_is_running(void) {
    try {
        return g_running.load() ? 1 : 0;  // 无锁，不被加载阻塞
    } catch (...) {
        return 0;
    }
}

int llmprovider_load_model(const char *model_path, const char *model_id) {
    try {
        std::lock_guard<std::mutex> op(g_op_mutex);
        llm_provider::set_last_error("");  // 入口清空陈旧错误
        if (!g_server) {
            llm_provider::set_last_error("service not started");
            return 0;
        }
        int ok;
        if (model_path == nullptr || *model_path == '\0') {
            // 空路径 = 卸载当前权重，服务保持运行但推理端点不可用。
            g_server->unload_model();
            ok = 1;
        } else {
            const std::string id = (model_id != nullptr) ? model_id : "";
            ok = g_server->load_model(model_path, id) ? 1 : 0;
        }
        refresh_state_locked();
        return ok;
    } catch (...) {
        llm_provider::set_last_error("llmprovider_load_model: C++ exception");
        return 0;
    }
}

/* ---- getters：加锁返回拷贝，各自 try/catch 保护 ---- */

const char *llmprovider_base_url(void) {
    try {
        std::lock_guard<std::mutex> lk(g_state_mutex);
        return cache_copy(g_state.base_url);
    } catch (...) { return ""; }
}

int llmprovider_port(void) {
    try {
        std::lock_guard<std::mutex> lk(g_state_mutex);
        return g_state.port;
    } catch (...) { return 0; }
}

const char *llmprovider_engine_name(void) {
    try {
        std::lock_guard<std::mutex> lk(g_state_mutex);
        return cache_copy(g_state.engine_name);
    } catch (...) { return ""; }
}

const char *llmprovider_model_id(void) {
    try {
        std::lock_guard<std::mutex> lk(g_state_mutex);
        return cache_copy(g_state.model_id);
    } catch (...) { return ""; }
}

int llmprovider_model_loaded(void) {
    try {
        std::lock_guard<std::mutex> lk(g_state_mutex);
        return g_state.model_loaded;
    } catch (...) { return 0; }
}

const char *llmprovider_api_key(void) {
    try {
        std::lock_guard<std::mutex> lk(g_state_mutex);
        return cache_copy(g_state.api_key);
    } catch (...) { return ""; }
}

const char *llmprovider_last_error(void) {
    try {
        // 返回拷贝到线程局部缓存；get_last_error() 内部自带锁，无静态缓存竞争。
        tls_cache = llm_provider::get_last_error();
        return tls_cache.c_str();
    } catch (...) { return ""; }
}

}  // extern "C"
