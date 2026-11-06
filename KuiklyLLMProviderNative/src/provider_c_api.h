#ifndef PROVIDER_C_API_H
#define PROVIDER_C_API_H

/*
 * provider_c_api.cpp 的内部 C ABI 声明（与实现文件同名成对）。
 * 三端平台桥（Android JNI / iOS ObjC++ / HarmonyOS NAPI）调用这里，
 * 本头声明的函数全部由 provider_c_api.cpp 定义；接入方不直接使用本头。
 *
 * 这不是对外契约：签名由共享 C++ 实现单方面定义，改动时同步更新三个
 * 桥文件的调用点即可；三端桥不负责实现这里的任何函数。
 *
 * 所有返回 `const char *` 的 getter 返回的指针仅在「同一线程下一次调用本 ABI
 * 中任意返回 const char* 的函数之前」有效（内部使用线程局部缓存返回拷贝）；
 * 调用方须立即复制，不得长期保存该指针。
 */
#ifdef __cplusplus
extern "C" {
#endif

/** 启动服务；port=0 不指定端口，由系统分配随机端口（实际端口从
 *  llmprovider_port() / llmprovider_base_url() 读取；与 apiKey 一样，不指定时随机生成）。
 *  port<0 或 >65535 为非法参数。model_path 可为 NULL（服务启动但不加载模型，
 *  推理端点返回 400 直到调用 load_model）。返回 1 表示成功。
 *  幂等：服务已在运行时直接刷新状态并返回 1，不重建服务、不轮换端口 / apiKey；
 *  只有 stop 后重新 start 才会分配新端口与 apiKey。 */
int llmprovider_start(int port, const char *model_path, const char *model_id);
void llmprovider_stop(void);
int  llmprovider_is_running(void);

/** 热切换 GGUF 模型；需先 start。返回 1 表示 llama.cpp 引擎已接管。
 *  model_path 传 NULL 或空串表示卸载当前权重：服务保持运行，但推理端点回到「无可用模型」。
 *  加载时 model_id 必填：不会沿用旧 id，传空则加载成功后 llmprovider_model_id() 也为空串。 */
int  llmprovider_load_model(const char *model_path, const char *model_id);

const char *llmprovider_base_url(void);
int  llmprovider_port(void);
const char *llmprovider_engine_name(void);
const char *llmprovider_model_id(void);
int  llmprovider_model_loaded(void);

/**
 * 本地服务的 API Key（形如 `kuikly-<22 字符 base64url>`，128 bit 系统熵）。
 *
 * 服务只绑定回环地址，但同一设备上的其他应用也能访问 127.0.0.1。
 * 因此除按 Host/Origin 策略放行的 OPTIONS 预检外，所有端点均要求
 * `Authorization: Bearer <key>`，缺失或不匹配时返回 401。
 *
 * 该 key 在服务生命周期内固定：重复调用 llmprovider_start 不会轮换，
 * 避免多个 Pager 先后启动时先启动者拿到旧 key 而 401。
 *
 * 未启动时返回空串。
 */
const char *llmprovider_api_key(void);

/** 最近一次引擎失败原因（空串表示无错误）。每个会改变状态的入口
 *  (start/load_model) 调用前都会清空，避免读到陈旧错误。 */
const char *llmprovider_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PROVIDER_C_API_H */
