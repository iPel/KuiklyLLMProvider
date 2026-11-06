cmake_minimum_required(VERSION 3.5)
project(kuikly_entry)

set(KUIKLY_ENTRY_ROOT_PATH .)
set(CMAKE_CXX_STANDARD 17)
if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

set(SOURCE_SET napi_init.cpp)

add_library(kuikly_entry SHARED ${SOURCE_SET})
set(OHOS_RENDER_MODULE ${CMAKE_CURRENT_SOURCE_DIR}/../../../oh_modules/@kuikly-open/render)
include_directories(
    ${KUIKLY_ENTRY_ROOT_PATH}
    ${KUIKLY_ENTRY_ROOT_PATH}/include
    ${OHOS_RENDER_MODULE}/include
)

# Link Kuikly render SDK (.so shipped inside the @kuikly-open/render HAR package)
set(OHOS_RENDER_DIR ${OHOS_RENDER_MODULE}/libs/${OHOS_ARCH})
add_library(kuikly_render SHARED IMPORTED)
set_target_properties(kuikly_render PROPERTIES IMPORTED_LOCATION ${OHOS_RENDER_DIR}/libkuikly.so)
target_link_libraries(kuikly_entry PUBLIC kuikly_render)

# Link system and business libraries
target_link_libraries(kuikly_entry PUBLIC
    libace_napi.z.so
    libace_ndk.z.so
    hilog_ndk.z.so
    librawfile.z.so
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a/libshared.so
)

# libllm_provider.so 由 KuiklyLLMProviderOhos HAR 自行编译并随 HAR 分发，
# hvigor 在打 HAP 时从依赖的 HAR 收集进 libs/；entry 不重复编译原生层。
# 本工程只负责 Kuikly 渲染桥 libkuikly_entry.so。
