#include <hilog/log.h>
#include <rawfile/raw_file_manager.h>
#include "napi/native_api.h"
#include "thirdparty/biz_entry/libshared_api.h"
#include "Kuikly/Kuikly.h"

static NativeResourceManager *g_resource_manager = nullptr;

static napi_value SetResourceManager(napi_env env, napi_callback_info info) {
    if (g_resource_manager) {
        return nullptr;
    }
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    g_resource_manager = OH_ResourceManager_InitNativeResourceManager(env, args[0]);
    return nullptr;
}

static void MyLogAdapter(int logLevel, const char *tag, const char *message) {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x1234, tag, "%{public}s", message);
}

static int64_t MyColorAdapter(const char *str) {
    return -1;
}

static int adapterRegistered = false;
static napi_value InitKuikly(napi_env env, napi_callback_info info) {
    if (!adapterRegistered) {
        KRRegisterLogAdapter(MyLogAdapter);
        KRRegisterColorAdapter(MyColorAdapter);
        adapterRegistered = true;
    }

    auto api = libshared_symbols();
    int handler = api->kotlin.root.initKuikly();
    napi_value result;
    napi_create_int32(env, handler, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"initKuikly", nullptr, InitKuikly, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setResourceManager", nullptr, SetResourceManager, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module entry_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "kuikly_entry",
    .nm_priv = static_cast<void *>(0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterKuikly_EntryModule(void) {
    napi_module_register(&entry_module);
}
