#include <jni.h>

#include "provider_c_api.h"

#include <cstdint>
#include <string>

namespace {

// JNI 的 *StringUTF* 接口使用 modified UTF-8：补充平面字符（emoji 等）以两个 3 字节代理编码、
// U+0000 以 2 字节编码，与 native 侧的标准 UTF-8 不同。直接互传会导致字符损坏，
// 且 NewStringUTF 收到 4 字节序列在 CheckJNI 下 abort。统一经 UTF-16 转换。

constexpr uint32_t kReplacement = 0xFFFD;

void append_utf8(std::string &out, uint32_t cp) {
    if (cp < 0x80) {
        out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
        out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
}

void append_utf16(std::u16string &out, uint32_t cp) {
    if (cp < 0x10000) {
        out.push_back(static_cast<char16_t>(cp));
    } else {
        cp -= 0x10000;
        out.push_back(static_cast<char16_t>(0xD800 + (cp >> 10)));
        out.push_back(static_cast<char16_t>(0xDC00 + (cp & 0x3FF)));
    }
}

/** UTF-16 → 标准 UTF-8；孤立代理替换为 U+FFFD。 */
std::string utf16_to_utf8(const char16_t *s, size_t n) {
    std::string out;
    out.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        uint32_t cp = s[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < n && s[i + 1] >= 0xDC00 && s[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (s[i + 1] - 0xDC00);
            ++i;
        } else if (cp >= 0xD800 && cp <= 0xDFFF) {
            cp = kReplacement;
        }
        append_utf8(out, cp);
    }
    return out;
}

/** 标准 UTF-8 → UTF-16；非法序列（截断、过长编码、代理区、超范围）按字节替换为 U+FFFD。 */
std::u16string utf8_to_utf16(const char *s) {
    std::u16string out;
    const auto *p = reinterpret_cast<const unsigned char *>(s);
    while (*p != 0) {
        const unsigned char c = *p;
        size_t need = 0;
        uint32_t cp = 0, min = 0;
        if (c < 0x80) { append_utf16(out, c); ++p; continue; }
        if ((c & 0xE0) == 0xC0) { need = 1; cp = c & 0x1F; min = 0x80; }
        else if ((c & 0xF0) == 0xE0) { need = 2; cp = c & 0x0F; min = 0x800; }
        else if ((c & 0xF8) == 0xF0) { need = 3; cp = c & 0x07; min = 0x10000; }
        else { append_utf16(out, kReplacement); ++p; continue; }
        size_t k = 1;
        for (; k <= need; ++k) {
            if ((p[k] & 0xC0) != 0x80) break;  // 遇到 '\0' 同样在此终止
            cp = (cp << 6) | (p[k] & 0x3F);
        }
        if (k <= need || cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
            append_utf16(out, kReplacement);
            ++p;
            continue;
        }
        append_utf16(out, cp);
        p += need + 1;
    }
    return out;
}

std::string jstring_to_std(JNIEnv *env, jstring value) {
    if (value == nullptr) return std::string();
    const jsize len = env->GetStringLength(value);
    const jchar *chars = env->GetStringChars(value, nullptr);
    if (chars == nullptr) return std::string();
    std::string result = utf16_to_utf8(reinterpret_cast<const char16_t *>(chars), static_cast<size_t>(len));
    env->ReleaseStringChars(value, chars);
    return result;
}

jstring to_jstring(JNIEnv *env, const char *value) {
    const std::u16string s = utf8_to_utf16(value != nullptr ? value : "");
    return env->NewString(reinterpret_cast<const jchar *>(s.data()), static_cast<jsize>(s.size()));
}

}  // namespace

extern "C" {

JNIEXPORT jint JNICALL
Java_com_kuikly_llmprovider_LLMProviderNativeBridge_nativeStart(
    JNIEnv *env, jobject, jint port, jstring modelPath, jstring modelId) {
    try {
        const std::string path = jstring_to_std(env, modelPath);
        const std::string id = jstring_to_std(env, modelId);
        return llmprovider_start(static_cast<int>(port), path.c_str(), id.c_str());
    } catch (...) {
        return 0;
    }
}

JNIEXPORT void JNICALL
Java_com_kuikly_llmprovider_LLMProviderNativeBridge_nativeStop(JNIEnv *, jobject) {
    try {
        llmprovider_stop();
    } catch (...) {
        // void：吞掉异常，绝不让它穿越 JNI 边界。
    }
}

JNIEXPORT jint JNICALL
Java_com_kuikly_llmprovider_LLMProviderNativeBridge_nativeLoadModel(
    JNIEnv *env, jobject, jstring modelPath, jstring modelId) {
    try {
        const std::string path = jstring_to_std(env, modelPath);
        const std::string id = jstring_to_std(env, modelId);
        return llmprovider_load_model(path.c_str(), id.c_str());
    } catch (...) {
        return 0;
    }
}

JNIEXPORT jboolean JNICALL
Java_com_kuikly_llmprovider_LLMProviderNativeBridge_nativeIsRunning(JNIEnv *, jobject) {
    try {
        return llmprovider_is_running() == 1 ? JNI_TRUE : JNI_FALSE;
    } catch (...) {
        return JNI_FALSE;
    }
}

JNIEXPORT jstring JNICALL
Java_com_kuikly_llmprovider_LLMProviderNativeBridge_nativeBaseUrl(JNIEnv *env, jobject) {
    try {
        return to_jstring(env, llmprovider_base_url());
    } catch (...) {
        return to_jstring(env, "");
    }
}

JNIEXPORT jstring JNICALL
Java_com_kuikly_llmprovider_LLMProviderNativeBridge_nativeApiKey(JNIEnv *env, jobject) {
    try {
        return to_jstring(env, llmprovider_api_key());
    } catch (...) {
        return to_jstring(env, "");
    }
}

JNIEXPORT jstring JNICALL
Java_com_kuikly_llmprovider_LLMProviderNativeBridge_nativeModelId(JNIEnv *env, jobject) {
    try {
        return to_jstring(env, llmprovider_model_id());
    } catch (...) {
        return to_jstring(env, "");
    }
}

JNIEXPORT jstring JNICALL
Java_com_kuikly_llmprovider_LLMProviderNativeBridge_nativeLastError(JNIEnv *env, jobject) {
    try {
        return to_jstring(env, llmprovider_last_error());
    } catch (...) {
        return to_jstring(env, "");
    }
}

}  // extern "C"
