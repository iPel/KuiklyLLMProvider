#include "napi/native_api.h"
#include "provider_c_api.h"

#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace {

napi_value MakeInt(napi_env env, int value) {
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value MakeUndefined(napi_env env) {
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

napi_value MakeEmptyString(napi_env env) {
    napi_value result = nullptr;
    napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &result);
    return result;
}

void SetBool(napi_env env, napi_value object, const char *key, bool value) {
    napi_value v = nullptr;
    if (napi_get_boolean(env, value, &v) == napi_ok) {
        napi_set_named_property(env, object, key, v);
    }
}

void SetInt(napi_env env, napi_value object, const char *key, int value) {
    napi_value v = nullptr;
    if (napi_create_int32(env, value, &v) == napi_ok) {
        napi_set_named_property(env, object, key, v);
    }
}

void SetString(napi_env env, napi_value object, const char *key, const char *value) {
    napi_value v = nullptr;
    if (napi_create_string_utf8(env, value ? value : "", NAPI_AUTO_LENGTH, &v) == napi_ok) {
        napi_set_named_property(env, object, key, v);
    }
}

/**
 * 先取长度再动态分配，避免固定长度缓冲截断；
 * 校验 napi_status 与参数类型，失败返回 false（out 置空），不抛异常穿越 NAPI 边界。
 */
bool GetString(napi_env env, napi_value value, std::string &out) {
    out.clear();
    if (env == nullptr || value == nullptr) return false;
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) return false;
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) return false;
    std::vector<char> buffer(length + 1, '\0');
    size_t written = 0;
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &written) != napi_ok) {
        return false;
    }
    out.assign(buffer.data(), written);
    return true;
}

napi_value MakeStatus(napi_env env, bool ok, const std::string &message) {
    napi_value object = nullptr;
    napi_create_object(env, &object);
    SetBool(env, object, "ok", ok);
    SetBool(env, object, "running", llmprovider_is_running() == 1);
    SetInt(env, object, "port", llmprovider_port());
    SetString(env, object, "baseUrl", llmprovider_base_url());
    SetString(env, object, "modelId", llmprovider_model_id());
    SetString(env, object, "engine", llmprovider_engine_name());
    SetBool(env, object, "modelLoaded", llmprovider_model_loaded() == 1);
    // ARKTS 侧发流式请求时要用它拼 Authorization 头
    SetString(env, object, "apiKey", llmprovider_api_key());
    SetString(env, object, "message", message.c_str());
    return object;
}

/* ---- 同步导出（每个都用 try/catch 保护，C++ 异常不穿越 NAPI 边界） ---- */

napi_value Start(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 3;
        napi_value args[3] = {nullptr};
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        int port = 0;  // 0 = 不指定，由内核分配随机端口
        if (argc > 0 && args[0] != nullptr) napi_get_value_int32(env, args[0], &port);
        std::string path;
        std::string id;
        if (argc > 1 && !GetString(env, args[1], path)) return MakeInt(env, -1);
        if (argc > 2 && !GetString(env, args[2], id)) return MakeInt(env, -1);
        return MakeInt(env, llmprovider_start(port, path.c_str(), id.c_str()));
    } catch (...) {
        return MakeInt(env, -1);
    }
}

napi_value Stop(napi_env env, napi_callback_info) {
    try {
        llmprovider_stop();
        return MakeUndefined(env);
    } catch (...) {
        return MakeUndefined(env);
    }
}

napi_value IsRunning(napi_env env, napi_callback_info) {
    try {
        return MakeInt(env, llmprovider_is_running());
    } catch (...) {
        return MakeInt(env, -1);
    }
}

napi_value LoadModel(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 2;
        napi_value args[2] = {nullptr};
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        std::string path;
        std::string id;
        if (argc > 0 && !GetString(env, args[0], path)) return MakeInt(env, -1);
        if (argc > 1 && !GetString(env, args[1], id)) return MakeInt(env, -1);
        return MakeInt(env, llmprovider_load_model(path.c_str(), id.c_str()));
    } catch (...) {
        return MakeInt(env, -1);
    }
}

napi_value LastError(napi_env env, napi_callback_info) {
    try {
        napi_value result = nullptr;
        napi_create_string_utf8(env, llmprovider_last_error(), NAPI_AUTO_LENGTH, &result);
        return result;
    } catch (...) {
        return MakeEmptyString(env);
    }
}

napi_value ModelLoaded(napi_env env, napi_callback_info) {
    try {
        return MakeInt(env, llmprovider_model_loaded());
    } catch (...) {
        return MakeInt(env, -1);
    }
}

napi_value Status(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 2;
        napi_value args[2] = {nullptr};
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        bool ok = true;
        if (argc > 0 && args[0] != nullptr) napi_get_value_bool(env, args[0], &ok);
        std::string message;
        if (argc > 1 && !GetString(env, args[1], message)) message.clear();
        return MakeStatus(env, ok, message);
    } catch (...) {
        napi_value object = nullptr;
        napi_create_object(env, &object);
        SetBool(env, object, "ok", false);
        SetString(env, object, "message", "internal error");
        return object;
    }
}

struct AsyncTask {
    napi_ref callback_ref = nullptr;
    napi_async_work work = nullptr;
    std::function<int()> job;
    int result = 0;
};

void AsyncExecute(napi_env /*env*/, void *data) {
    AsyncTask *task = static_cast<AsyncTask *>(data);
    try {
        task->result = task->job ? task->job() : -1;
    } catch (...) {
        task->result = -1;  // 异常不逃逸工作线程
    }
}

void AsyncComplete(napi_env env, napi_status status, void *data) {
    std::unique_ptr<AsyncTask> task(static_cast<AsyncTask *>(data));
    if (status != napi_cancelled && task->callback_ref != nullptr) {
        napi_value callback = nullptr;
        if (napi_get_reference_value(env, task->callback_ref, &callback) == napi_ok &&
            callback != nullptr) {
            napi_value undefined = nullptr;
            napi_get_undefined(env, &undefined);
            napi_value arg = MakeInt(env, task->result);
            napi_value ignored = nullptr;
            napi_call_function(env, undefined, callback, 1, &arg, &ignored);
        }
    }
    if (task->callback_ref != nullptr) napi_delete_reference(env, task->callback_ref);
    if (task->work != nullptr) napi_delete_async_work(env, task->work);
}

/** 从 callback_index 位置取出 JS 回调，把 job 投递到后台线程执行。 */
napi_value QueueAsync(napi_env env, napi_callback_info info, size_t callback_index,
                      std::function<int()> job) {
    size_t argc = callback_index + 1;
    std::vector<napi_value> args(argc, nullptr);
    napi_get_cb_info(env, info, &argc, args.data(), nullptr, nullptr);
    napi_value callback = (argc > callback_index) ? args[callback_index] : nullptr;
    if (callback == nullptr) return MakeInt(env, -1);
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, callback, &type) != napi_ok || type != napi_function) {
        return MakeInt(env, -1);
    }

    auto task = std::make_unique<AsyncTask>();
    task->job = std::move(job);
    if (napi_create_reference(env, callback, 1, &task->callback_ref) != napi_ok) {
        return MakeInt(env, -1);
    }
    napi_value resource_name = nullptr;
    napi_create_string_utf8(env, "llmprovider_async", NAPI_AUTO_LENGTH, &resource_name);
    if (napi_create_async_work(env, nullptr, resource_name, AsyncExecute, AsyncComplete,
                               task.get(), &task->work) != napi_ok) {
        napi_delete_reference(env, task->callback_ref);
        return MakeInt(env, -1);
    }
    if (napi_queue_async_work(env, task->work) != napi_ok) {
        napi_delete_reference(env, task->callback_ref);
        napi_delete_async_work(env, task->work);
        return MakeInt(env, -1);
    }
    task.release();  // 所有权交给 AsyncComplete
    return MakeUndefined(env);
}

napi_value StartAsync(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 4;
        napi_value args[4] = {nullptr};
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        int port = 0;  // 0 = 不指定，由内核分配随机端口
        if (argc > 0 && args[0] != nullptr &&
            napi_get_value_int32(env, args[0], &port) != napi_ok) {
            return MakeInt(env, -1);
        }
        std::string path;
        std::string id;
        if (argc > 1 && !GetString(env, args[1], path)) return MakeInt(env, -1);
        if (argc > 2 && !GetString(env, args[2], id)) return MakeInt(env, -1);
        // path/id 按值复制进 lambda，后台线程只访问这些 C++ 副本
        return QueueAsync(env, info, 3, [port, path, id]() -> int {
            return llmprovider_start(port, path.c_str(), id.c_str());
        });
    } catch (...) {
        return MakeInt(env, -1);
    }
}

/** stop 需等待在途连接与生成退出，放到后台线程，避免阻塞 Kuikly 线程。 */
napi_value StopAsync(napi_env env, napi_callback_info info) {
    try {
        return QueueAsync(env, info, 0, []() -> int {
            llmprovider_stop();
            return 1;
        });
    } catch (...) {
        return MakeInt(env, -1);
    }
}

napi_value LoadModelAsync(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 3;
        napi_value args[3] = {nullptr};
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        std::string path;
        std::string id;
        if (argc > 0 && !GetString(env, args[0], path)) return MakeInt(env, -1);
        if (argc > 1 && !GetString(env, args[1], id)) return MakeInt(env, -1);
        return QueueAsync(env, info, 2, [path, id]() -> int {
            return llmprovider_load_model(path.c_str(), id.c_str());
        });
    } catch (...) {
        return MakeInt(env, -1);
    }
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startAsync", nullptr, StartAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopAsync", nullptr, StopAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadModel", nullptr, LoadModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadModelAsync", nullptr, LoadModelAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"modelLoaded", nullptr, ModelLoaded, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lastError", nullptr, LastError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"status", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module llmprovider_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "llm_provider",
    .nm_priv = static_cast<void *>(0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterLlmkitModule(void) {
    napi_module_register(&llmprovider_module);
}
