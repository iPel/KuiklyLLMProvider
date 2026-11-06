#pragma once
#include <memory>
#include <string>

namespace llm_provider {

class HttpServer {
public:
    /** api_key 为空时自动生成一个；服务整个生命周期内该 key 不会轮换。 */
    HttpServer(int port, int n_ctx, int n_threads, double default_temperature,
               const std::string& api_key = "");
    ~HttpServer();

    bool start();
    void stop();
    bool running() const;
    bool load_model(const std::string& model_path, const std::string& model_id);
    /** 释放当前权重并清空 model_id；服务仍在运行，但推理端点不可用。 */
    void unload_model();

    /** 运行中返回 `http://127.0.0.1:<实际端口>`；未启动 / stop 后为空串。 */
    std::string base_url() const;
    /** 运行中返回实际绑定端口（port=0 时为内核分配结果）；未启动 / stop 后为 0。 */
    int port() const;
    std::string engine_name() const;
    std::string model_id() const;
    bool model_loaded() const;
    /** 当前生效的 API Key；客户端需放进 `Authorization: Bearer <key>`。 */
    std::string api_key() const;

private:
    struct Impl;
    // 用 shared_ptr 让 accept 线程与每个连接线程都持有 Impl 的共享所有权。
    // 即使 HttpServer 先被析构，Impl 也要等所有在途连接线程 join 结束后才释放，
    // 彻底消除「detach 线程持裸 Impl*」的悬空指针。
    std::shared_ptr<Impl> impl_;
};

}  // namespace llm_provider
