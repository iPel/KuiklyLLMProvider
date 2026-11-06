cmake_minimum_required(VERSION 3.5)
project(llmprovider_ohos LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
# 共享 C++ 层位于独立目录 KuiklyLLMProviderNative/（由 iOS pod 与鸿蒙 HAR 共同引用）。
# 本文件位于 src/main/cpp/，向上四级才是仓库根目录。
set(NATIVE_ROOT ${CMAKE_CURRENT_LIST_DIR}/../../../../KuiklyLLMProviderNative)

# 共享 C++ 层：兼容 OpenAI API 的 HTTP 服务与唯一的 llama.cpp 引擎
add_library(llmprovider_native STATIC
    ${NATIVE_ROOT}/src/engine_common.cpp
    ${NATIVE_ROOT}/src/provider_c_api.cpp
    ${NATIVE_ROOT}/src/http_server.cpp
    ${NATIVE_ROOT}/src/llama_engine.cpp
)
target_include_directories(llmprovider_native PUBLIC
    ${NATIVE_ROOT}/src
)

# ---------------------------------------------------------------------------
# GGUF 推理依赖（llama.cpp / ggml 静态库）由本 HAR 自行解析，宿主工程不参与。
# 默认使用仓库内 prebuilt/llama/ 的带符号静态库，无需外部依赖。
#
# 覆盖方式（CMake 变量优先，其次同名环境变量）：
#   LLMPROVIDER_LLAMA_DIR      llama.cpp 根目录（含 include/llama.h）
#   LLMPROVIDER_LLAMA_LIB_DIR  含 libllama.a / libggml*.a 的目录
# 只显式指定 DIR 且指向另一份 llama.cpp 源码树时，LIB_DIR 取 ${DIR}/lib，
# 避免用外部头文件去配 prebuilt 的静态库。指向 llama.cpp 源码目录时会自动补
# ggml/include。头文件与静态库缺失时直接 FATAL_ERROR：本 HAR 不提供模拟引擎，
# 也不会发出一个只能回显假内容的 .so。
# ---------------------------------------------------------------------------
if(NOT LLMPROVIDER_LLAMA_DIR AND DEFINED ENV{LLMPROVIDER_LLAMA_DIR})
    set(LLMPROVIDER_LLAMA_DIR "$ENV{LLMPROVIDER_LLAMA_DIR}")
endif()
if(NOT LLMPROVIDER_LLAMA_LIB_DIR AND DEFINED ENV{LLMPROVIDER_LLAMA_LIB_DIR})
    set(LLMPROVIDER_LLAMA_LIB_DIR "$ENV{LLMPROVIDER_LLAMA_LIB_DIR}")
endif()

set(LLMPROVIDER_PREBUILT_DIR     "${NATIVE_ROOT}/prebuilt/llama")
set(LLMPROVIDER_PREBUILT_LIB_DIR "${LLMPROVIDER_PREBUILT_DIR}/ohos/arm64-v8a")
if(NOT LLMPROVIDER_LLAMA_DIR)
    set(LLMPROVIDER_LLAMA_DIR "${LLMPROVIDER_PREBUILT_DIR}")
endif()
if(NOT LLMPROVIDER_LLAMA_LIB_DIR)
    # 比较前先规范化：默认值经 CMAKE_CURRENT_LIST_DIR 拼接会带 ../../，
    # 与调用方传入的绝对路径字符串不相等，否则会把「显式指向 prebuilt 树」
    # 误判成外部源码树，导致库目录落到 ${DIR}/lib 并在链接期失败。
    get_filename_component(_llmprovider_dir      "${LLMPROVIDER_LLAMA_DIR}"     REALPATH)
    get_filename_component(_llmprovider_prebuilt "${LLMPROVIDER_PREBUILT_DIR}"  REALPATH)
    if(_llmprovider_dir STREQUAL _llmprovider_prebuilt)
        set(LLMPROVIDER_LLAMA_LIB_DIR "${LLMPROVIDER_PREBUILT_LIB_DIR}")
    else()
        set(LLMPROVIDER_LLAMA_LIB_DIR "${LLMPROVIDER_LLAMA_DIR}/lib")
    endif()
endif()

set(llm_provider_ok TRUE)
set(llm_provider_reason "")
if(NOT LLMPROVIDER_LLAMA_DIR)
    set(llm_provider_ok FALSE)
    set(llm_provider_reason "未指定 LLMPROVIDER_LLAMA_DIR")
elseif(NOT LLMPROVIDER_LLAMA_LIB_DIR)
    set(llm_provider_ok FALSE)
    set(llm_provider_reason "未指定 LLMPROVIDER_LLAMA_LIB_DIR")
elseif(NOT EXISTS "${LLMPROVIDER_LLAMA_DIR}/include/llama.h")
    set(llm_provider_ok FALSE)
    set(llm_provider_reason "${LLMPROVIDER_LLAMA_DIR}/include/llama.h 不存在")
else()
    foreach(lib llama ggml-cpu ggml-base ggml)
        # 只记录第一个缺失的库，避免 foreach 把原因覆盖成最后一个。
        if(llm_provider_ok AND NOT EXISTS "${LLMPROVIDER_LLAMA_LIB_DIR}/lib${lib}.a")
            set(llm_provider_ok FALSE)
            set(llm_provider_reason "缺少 ${LLMPROVIDER_LLAMA_LIB_DIR}/lib${lib}.a")
        endif()
    endforeach()
endif()

if(llm_provider_ok)
    message(STATUS "llm_provider: 启用 llama.cpp GGUF 推理 (headers=${LLMPROVIDER_LLAMA_DIR}/include, libs=${LLMPROVIDER_LLAMA_LIB_DIR})")
    target_compile_definitions(llmprovider_native PUBLIC LLMPROVIDER_WITH_LLAMA=1)
    target_include_directories(llmprovider_native PUBLIC
        ${LLMPROVIDER_LLAMA_DIR}/include)
    if(EXISTS "${LLMPROVIDER_LLAMA_DIR}/ggml/include")
        target_include_directories(llmprovider_native PUBLIC
            ${LLMPROVIDER_LLAMA_DIR}/ggml/include)
    endif()

    # 静态库按依赖顺序声明，CMake 会自动推导正确的链接顺序
    add_library(llama_cpp_ggml      STATIC IMPORTED)
    set_target_properties(llama_cpp_ggml PROPERTIES
        IMPORTED_LOCATION "${LLMPROVIDER_LLAMA_LIB_DIR}/libggml.a")

    add_library(llama_cpp_ggml_base STATIC IMPORTED)
    set_target_properties(llama_cpp_ggml_base PROPERTIES
        IMPORTED_LOCATION "${LLMPROVIDER_LLAMA_LIB_DIR}/libggml-base.a"
        INTERFACE_LINK_LIBRARIES "llama_cpp_ggml")

    add_library(llama_cpp_ggml_cpu  STATIC IMPORTED)
    set_target_properties(llama_cpp_ggml_cpu PROPERTIES
        IMPORTED_LOCATION "${LLMPROVIDER_LLAMA_LIB_DIR}/libggml-cpu.a"
        INTERFACE_LINK_LIBRARIES "llama_cpp_ggml_base;llama_cpp_ggml")

    add_library(llama_cpp           STATIC IMPORTED)
    set_target_properties(llama_cpp PROPERTIES
        IMPORTED_LOCATION "${LLMPROVIDER_LLAMA_LIB_DIR}/libllama.a"
        INTERFACE_LINK_LIBRARIES "llama_cpp_ggml_cpu;llama_cpp_ggml_base;llama_cpp_ggml")

    target_link_libraries(llmprovider_native PUBLIC llama_cpp)
else()
    message(FATAL_ERROR
        "llm_provider: llama.cpp 依赖缺失（${llm_provider_reason}）。"
        " 本 HAR 必须链接 llama.cpp / ggml 静态库，不提供模拟引擎；"
        " 请确认 KuiklyLLMProviderNative/prebuilt/llama/ohos/arm64-v8a/ 已入库，"
        " 或用 LLMPROVIDER_LLAMA_DIR / LLMPROVIDER_LLAMA_LIB_DIR 指定有效路径。")
endif()

# NAPI 桥：向 ArkTS Module 暴露 start/stop/status/loadModel
add_library(llm_provider SHARED provider_napi.cpp)
target_include_directories(llm_provider PRIVATE ${NATIVE_ROOT}/src)
target_link_libraries(llm_provider PRIVATE
    llmprovider_native
    libace_napi.z.so
    hilog_ndk.z.so
)

set(LLMPROVIDER_SYMBOL_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../build/native-symbols"
    CACHE PATH "Directory for unstripped native binaries" FORCE)
add_custom_command(TARGET llm_provider POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${LLMPROVIDER_SYMBOL_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy
            "$<TARGET_FILE:llm_provider>"
            "${LLMPROVIDER_SYMBOL_DIR}/libllm_provider.so.unstripped"
    COMMAND ${CMAKE_STRIP} --strip-all "$<TARGET_FILE:llm_provider>"
    COMMENT "Keeping unstripped binary and stripping libllm_provider.so"
)
