cmake_minimum_required(VERSION 3.18.1)
project(llm_provider_android LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 共享 C++ 层位于独立目录 KuiklyLLMProviderNative/（iOS Pod 与鸿蒙 HAR 引用同一份源码）。
# 本文件位于 src/main/cpp/，向上四级才是仓库根目录。
set(NATIVE_ROOT ${CMAKE_CURRENT_LIST_DIR}/../../../../KuiklyLLMProviderNative)

# 优化级别由 AGP 的 CMAKE_BUILD_TYPE 决定，构建脚本不覆盖 -O 参数。

# ---------------------------------------------------------------------------
# GGUF 推理依赖是本模块的硬要求：llama_engine.cpp 在未定义
# LLMPROVIDER_WITH_LLAMA 时会直接 #error，本 CMake 也不提供任何空实现/模拟引擎。
# 默认使用仓库内 prebuilt/llama/ 的带符号静态库；缺头文件或缺任一 .a 都
# FATAL_ERROR，绝不产出一个只能回显假内容的 .so。
#
# 覆盖方式（Gradle -P 属性、CMake 变量或同名环境变量，优先级依次降低）：
#   LLMPROVIDER_LLAMA_DIR      含 include/llama.h 的 llama.cpp 根目录
#   LLMPROVIDER_LLAMA_LIB_DIR  含 libllama.a / libggml*.a 的目录
# ---------------------------------------------------------------------------
foreach(_var LLMPROVIDER_LLAMA_DIR LLMPROVIDER_LLAMA_LIB_DIR)
    if(NOT ${_var} AND DEFINED ENV{${_var}})
        set(${_var} "$ENV{${_var}}")
    endif()
endforeach()

set(LLMPROVIDER_PREBUILT_DIR     "${NATIVE_ROOT}/prebuilt/llama")
set(LLMPROVIDER_PREBUILT_LIB_DIR "${LLMPROVIDER_PREBUILT_DIR}/android/${ANDROID_ABI}")
if(NOT LLMPROVIDER_LLAMA_DIR)
    set(LLMPROVIDER_LLAMA_DIR "${LLMPROVIDER_PREBUILT_DIR}")
endif()
if(NOT LLMPROVIDER_LLAMA_LIB_DIR)
    get_filename_component(_llmprovider_dir      "${LLMPROVIDER_LLAMA_DIR}"    REALPATH)
    get_filename_component(_llmprovider_prebuilt "${LLMPROVIDER_PREBUILT_DIR}" REALPATH)
    if(_llmprovider_dir STREQUAL _llmprovider_prebuilt)
        set(LLMPROVIDER_LLAMA_LIB_DIR "${LLMPROVIDER_PREBUILT_LIB_DIR}")
    else()
        set(LLMPROVIDER_LLAMA_LIB_DIR "${LLMPROVIDER_LLAMA_DIR}/lib")
    endif()
endif()

if(NOT EXISTS "${LLMPROVIDER_LLAMA_DIR}/include/llama.h")
    message(FATAL_ERROR "llm_provider(android): 缺少 ${LLMPROVIDER_LLAMA_DIR}/include/llama.h；请设置 LLMPROVIDER_LLAMA_DIR")
endif()
foreach(lib llama ggml-cpu ggml-base ggml)
    if(NOT EXISTS "${LLMPROVIDER_LLAMA_LIB_DIR}/lib${lib}.a")
        message(FATAL_ERROR "llm_provider(android): 缺少 ${LLMPROVIDER_LLAMA_LIB_DIR}/lib${lib}.a (ABI=${ANDROID_ABI})；请设置 LLMPROVIDER_LLAMA_LIB_DIR。本模块不提供模拟引擎。")
    endif()
endforeach()
message(STATUS "llm_provider(android): llama.cpp headers=${LLMPROVIDER_LLAMA_DIR}/include libs=${LLMPROVIDER_LLAMA_LIB_DIR}")

# 静态库按依赖顺序声明，CMake 会自动推导正确的链接顺序。
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

add_library(llm_provider SHARED
    ${NATIVE_ROOT}/src/engine_common.cpp
    ${NATIVE_ROOT}/src/provider_c_api.cpp
    ${NATIVE_ROOT}/src/http_server.cpp
    ${NATIVE_ROOT}/src/llama_engine.cpp
    # JNI 桥是 Android 平台专属代码，与本文件同目录，不放在共享 C++ 层。
    ${CMAKE_CURRENT_LIST_DIR}/android_jni.cpp
)
target_compile_definitions(llm_provider PRIVATE LLMPROVIDER_WITH_LLAMA=1)
# Android 15+ 的 16 KB 页设备要求 LOAD 段按 16 KB 对齐；NDK r26 默认 4 KB，需显式指定。
target_link_options(llm_provider PRIVATE "-Wl,-z,max-page-size=16384")
target_include_directories(llm_provider PRIVATE
    ${NATIVE_ROOT}/src
    ${LLMPROVIDER_LLAMA_DIR}/include
)
if(EXISTS "${LLMPROVIDER_LLAMA_DIR}/ggml/include")
    target_include_directories(llm_provider PRIVATE ${LLMPROVIDER_LLAMA_DIR}/ggml/include)
endif()
find_library(android-log-lib log)
find_library(android-native-lib android)
target_link_libraries(llm_provider PRIVATE
    llama_cpp
    ${android-log-lib}
    ${android-native-lib}
    atomic
)

set(LLMPROVIDER_SYMBOL_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../build/native-symbols"
    CACHE PATH "Directory for unstripped Android native binaries")
add_custom_command(TARGET llm_provider POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${LLMPROVIDER_SYMBOL_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy
            "$<TARGET_FILE:llm_provider>"
            "${LLMPROVIDER_SYMBOL_DIR}/libllm_provider.so.unstripped"
    COMMAND ${CMAKE_STRIP} --strip-all "$<TARGET_FILE:llm_provider>"
    COMMAND python3 "${CMAKE_CURRENT_LIST_DIR}/sanitize_symbols.py"
            "$<TARGET_FILE:llm_provider>"
            "${LLMPROVIDER_SYMBOL_DIR}/libllm_provider.so.unstripped"
    COMMENT "Keeping unstripped binary, stripping and neutralizing build paths"
)
