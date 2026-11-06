#pragma once
// 无第三方依赖的最小 JSON 解析/序列化，仅服务于 OpenAI 兼容协议的字段子集。
// 严格遵循 RFC 8259 语法：object / array / string(含 \uXXXX 与代理对) /
// number / bool / null；解析有递归深度上限、尾部校验、完整 UTF-8 校验，
// 序列化保证输出合法 JSON（不产生 WTF-8 / inf / nan / 未转义 U+2028）。
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace llm_provider {

class Json {
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    Type type = Type::Null;
    bool boolean = false;
    double number = 0.0;
    std::string string;
    std::vector<Json> array;
    std::map<std::string, Json> object;

    static Json make_null() { return Json(); }
    static Json make_bool(bool v) { Json j; j.type = Type::Bool; j.boolean = v; return j; }
    static Json make_number(double v) { Json j; j.type = Type::Number; j.number = v; return j; }
    static Json make_string(const std::string& v) { Json j; j.type = Type::String; j.string = v; return j; }
    static Json make_array() { Json j; j.type = Type::Array; return j; }
    static Json make_object() { Json j; j.type = Type::Object; return j; }

    bool is_null() const { return type == Type::Null; }
    bool is_string() const { return type == Type::String; }
    bool is_array() const { return type == Type::Array; }
    bool is_object() const { return type == Type::Object; }

    const Json* find(const std::string& key) const {
        if (type != Type::Object) return nullptr;
        auto it = object.find(key);
        return it == object.end() ? nullptr : &it->second;
    }
    std::string str(const std::string& key, const std::string& fallback = "") const {
        const Json* v = find(key);
        return (v && v->is_string()) ? v->string : fallback;
    }
    // double -> int 前先做有限性与范围检查，避免超范围 / NaN 的 UB。
    int integer(const std::string& key, int fallback = 0) const {
        const Json* v = find(key);
        if (!v || v->type != Type::Number) return fallback;
        const double d = v->number;
        if (!std::isfinite(d)) return fallback;
        if (d > static_cast<double>(std::numeric_limits<int>::max()) ||
            d < static_cast<double>(std::numeric_limits<int>::min())) {
            return fallback;
        }
        return static_cast<int>(d);
    }
    double real(const std::string& key, double fallback = 0.0) const {
        const Json* v = find(key);
        return (v && v->type == Type::Number) ? v->number : fallback;
    }
    bool flag(const std::string& key, bool fallback = false) const {
        const Json* v = find(key);
        return (v && v->type == Type::Bool) ? v->boolean : fallback;
    }
    void set(const std::string& key, const Json& value) { type = Type::Object; object[key] = value; }
    void push(const Json& value) { type = Type::Array; array.push_back(value); }

    static Json parse(const std::string& text) {
        // 先整段校验 UTF-8 合法性，杜绝把非法字节透传进字符串值。
        if (!valid_utf8(text)) throw std::runtime_error("invalid UTF-8 in JSON");
        Parser p(text);
        Json value = p.parse_value(0);
        p.skip_ws();
        // 尾部除空白外不得有任何残留，否则是拼接/截断的畸形报文。
        if (p.i != text.size()) throw std::runtime_error("trailing garbage after JSON value");
        return value;
    }

    std::string dump() const {
        switch (type) {
            case Type::Null: return "null";
            case Type::Bool: return boolean ? "true" : "false";
            case Type::Number: {
                // inf / nan 不是合法 JSON 数值，退化为 null 而非输出 "inf"/"nan"。
                if (!std::isfinite(number)) return "null";
                // 仅对 2^53 内可精确表示的整数用整数格式，避免 long long 截断/UB。
                if (number == std::floor(number) &&
                    number >= -9007199254740992.0 && number <= 9007199254740992.0) {
                    char buf[32];
                    std::snprintf(buf, sizeof(buf), "%lld", static_cast<long long>(number));
                    return buf;
                }
                char buf[64];
                std::snprintf(buf, sizeof(buf), "%.17g", number);
                return buf;
            }
            case Type::String: return quote(string);
            case Type::Array: {
                // 深度是解析侧约束；dump 仅用于本进程构造的浅结构，无需深度限制。
                std::string out = "[";
                for (size_t i = 0; i < array.size(); ++i) {
                    if (i) out += ',';
                    out += array[i].dump();
                }
                return out + "]";
            }
            case Type::Object: {
                std::string out = "{";
                bool first = true;
                for (const auto& kv : object) {
                    if (!first) out += ',';
                    first = false;
                    out += quote(kv.first) + ":" + kv.second.dump();
                }
                return out + "}";
            }
        }
        return "null";
    }

    // 转义控制字符与 U+2028/U+2029（后者在 JS 中是行分隔符）。
    // 输入已由 parse() / 调用方保证是合法 UTF-8，多字节字符按原字节透传。
    static std::string quote(const std::string& s) {
        std::string out = "\"";
        for (size_t i = 0; i < s.size();) {
            const unsigned char c = static_cast<unsigned char>(s[i]);
            if (c == 0xE2 && i + 2 < s.size() &&
                static_cast<unsigned char>(s[i + 1]) == 0x80 &&
                (static_cast<unsigned char>(s[i + 2]) == 0xA8 ||
                 static_cast<unsigned char>(s[i + 2]) == 0xA9)) {
                out += (static_cast<unsigned char>(s[i + 2]) == 0xA8)
                           ? "\\u2028" : "\\u2029";
                i += 3;
                continue;
            }
            switch (c) {
                case '"': out += "\\\""; break;
                case '\\': out += "\\\\"; break;
                case '\b': out += "\\b"; break;
                case '\f': out += "\\f"; break;
                case '\n': out += "\\n"; break;
                case '\r': out += "\\r"; break;
                case '\t': out += "\\t"; break;
                default:
                    if (c < 0x20) {
                        char buf[8];
                        std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                        out += buf;
                    } else {
                        out += static_cast<char>(c);
                    }
            }
            ++i;
        }
        return out + "\"";
    }

private:
    // 完整 UTF-8 校验：拒绝孤立续字节、过长编码、代理码点、> U+10FFFF。
    static bool valid_utf8(const std::string& s) {
        const size_t n = s.size();
        size_t i = 0;
        while (i < n) {
            const unsigned char c = static_cast<unsigned char>(s[i]);
            if (c < 0x80) { ++i; continue; }
            int len;
            unsigned cp;
            if ((c & 0xE0) == 0xC0) { len = 2; cp = c & 0x1F; }
            else if ((c & 0xF0) == 0xE0) { len = 3; cp = c & 0x0F; }
            else if ((c & 0xF8) == 0xF0) { len = 4; cp = c & 0x07; }
            else return false;  // 0x80..0xBF 续字节开头 / 0xF8+ 非法
            if (i + static_cast<size_t>(len) > n) return false;
            for (int k = 1; k < len; ++k) {
                const unsigned char cc = static_cast<unsigned char>(s[i + static_cast<size_t>(k)]);
                if ((cc & 0xC0) != 0x80) return false;
                cp = (cp << 6) | (cc & 0x3F);
            }
            if (len == 2 && cp < 0x80) return false;
            if (len == 3 && cp < 0x800) return false;
            if (len == 4 && cp < 0x10000) return false;
            if (cp >= 0xD800 && cp <= 0xDFFF) return false;  // 代理区不是标量
            if (cp > 0x10FFFF) return false;
            i += static_cast<size_t>(len);
        }
        return true;
    }

    struct Parser {
        const std::string& s;
        size_t i = 0;
        static constexpr int kMaxDepth = 64;  // 递归深度上限
        explicit Parser(const std::string& text) : s(text) {}

        void skip_ws() {
            while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) ++i;
        }
        char peek() { return i < s.size() ? s[i] : '\0'; }
        void expect(char c) {
            if (peek() != c) throw std::runtime_error("invalid JSON");
            ++i;
        }
        Json parse_value(int depth) {
            if (depth > kMaxDepth) throw std::runtime_error("JSON nesting too deep");
            skip_ws();
            char c = peek();
            if (c == '{') return parse_object(depth);
            if (c == '[') return parse_array(depth);
            if (c == '"') return Json::make_string(parse_string());
            if (c == 't') { consume("true"); return Json::make_bool(true); }
            if (c == 'f') { consume("false"); return Json::make_bool(false); }
            if (c == 'n') { consume("null"); return Json::make_null(); }
            return parse_number();
        }
        void consume(const char* lit) {
            for (const char* p = lit; *p; ++p, ++i) {
                if (i >= s.size() || s[i] != *p) throw std::runtime_error("invalid JSON literal");
            }
        }
        Json parse_object(int depth) {
            Json j = Json::make_object();
            expect('{');
            skip_ws();
            if (peek() == '}') { ++i; return j; }
            while (true) {
                skip_ws();
                std::string key = parse_string();
                skip_ws();
                expect(':');
                j.set(key, parse_value(depth + 1));
                skip_ws();
                if (peek() == ',') { ++i; continue; }
                expect('}');
                break;
            }
            return j;
        }
        Json parse_array(int depth) {
            Json j = Json::make_array();
            expect('[');
            skip_ws();
            if (peek() == ']') { ++i; return j; }
            while (true) {
                j.push(parse_value(depth + 1));
                skip_ws();
                if (peek() == ',') { ++i; continue; }
                expect(']');
                break;
            }
            return j;
        }
        std::string parse_string() {
            expect('"');
            std::string out;
            while (i < s.size()) {
                const unsigned char c = static_cast<unsigned char>(s[i++]);
                if (c == '"') return out;
                if (c < 0x20) throw std::runtime_error("unescaped control character in string");
                if (c != '\\') { out += static_cast<char>(c); continue; }
                if (i >= s.size()) throw std::runtime_error("bad escape at end of input");
                const char e = s[i++];
                switch (e) {
                    case '"': out += '"'; break;
                    case '\\': out += '\\'; break;
                    case '/': out += '/'; break;
                    case 'b': out += '\b'; break;
                    case 'f': out += '\f'; break;
                    case 'n': out += '\n'; break;
                    case 'r': out += '\r'; break;
                    case 't': out += '\t'; break;
                    case 'u': {
                        unsigned cp = read_hex4();
                        if (cp >= 0xD800 && cp <= 0xDBFF) {
                            // 高位代理必须紧跟 \uXXXX 低位代理，否则是孤立代理（WTF-8 来源）。
                            if (i + 1 >= s.size() || s[i] != '\\' || s[i + 1] != 'u') {
                                throw std::runtime_error("unpaired high surrogate");
                            }
                            i += 2;
                            const unsigned low = read_hex4();
                            if (low < 0xDC00 || low > 0xDFFF) {
                                throw std::runtime_error("invalid low surrogate");
                            }
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                        } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                            throw std::runtime_error("lone low surrogate");
                        }
                        append_utf8(out, cp);
                        break;
                    }
                    default:
                        // 未知转义一律拒绝，不放行成裸字符。
                        throw std::runtime_error("invalid escape sequence");
                }
            }
            throw std::runtime_error("unterminated string");
        }
        // 必须恰好 4 个十六进制字符，非法字符抛错而非静默丢弃。
        unsigned read_hex4() {
            if (i + 4 > s.size()) throw std::runtime_error("incomplete \\u escape");
            unsigned v = 0;
            for (int k = 0; k < 4; ++k) {
                const char c = s[i++];
                v <<= 4;
                if (c >= '0' && c <= '9') v |= static_cast<unsigned>(c - '0');
                else if (c >= 'a' && c <= 'f') v |= static_cast<unsigned>(c - 'a' + 10);
                else if (c >= 'A' && c <= 'F') v |= static_cast<unsigned>(c - 'A' + 10);
                else throw std::runtime_error("invalid hex digit in \\u escape");
            }
            return v;
        }
        static void append_utf8(std::string& out, unsigned cp) {
            // cp 已由调用方保证是合法 Unicode 标量（非代理、<= 0x10FFFF）。
            if (cp <= 0x7F) out += static_cast<char>(cp);
            else if (cp <= 0x7FF) {
                out += static_cast<char>(0xC0 | (cp >> 6));
                out += static_cast<char>(0x80 | (cp & 0x3F));
            } else if (cp <= 0xFFFF) {
                out += static_cast<char>(0xE0 | (cp >> 12));
                out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                out += static_cast<char>(0x80 | (cp & 0x3F));
            } else {
                out += static_cast<char>(0xF0 | (cp >> 18));
                out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
                out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                out += static_cast<char>(0x80 | (cp & 0x3F));
            }
        }
        // 严格 JSON 数字文法 + 有限性检查，杜绝 "+" 前缀、前导 0、
        // 悬空 "1e"/"1."、inf / nan 等非法输出。
        Json parse_number() {
            const size_t start = i;
            if (peek() == '-') ++i;
            if (i >= s.size()) throw std::runtime_error("invalid JSON number");
            if (s[i] == '0') {
                ++i;
                if (i < s.size() && is_digit(s[i])) throw std::runtime_error("leading zero in number");
            } else if (s[i] >= '1' && s[i] <= '9') {
                while (i < s.size() && is_digit(s[i])) ++i;
            } else {
                throw std::runtime_error("invalid JSON number");
            }
            if (i < s.size() && s[i] == '.') {
                ++i;
                if (i >= s.size() || !is_digit(s[i])) throw std::runtime_error("invalid fraction");
                while (i < s.size() && is_digit(s[i])) ++i;
            }
            if (i < s.size() && (s[i] == 'e' || s[i] == 'E')) {
                ++i;
                if (i < s.size() && (s[i] == '+' || s[i] == '-')) ++i;
                if (i >= s.size() || !is_digit(s[i])) throw std::runtime_error("invalid exponent");
                while (i < s.size() && is_digit(s[i])) ++i;
            }
            const std::string token = s.substr(start, i - start);
            char* end = nullptr;
            const double val = std::strtod(token.c_str(), &end);
            if (end != token.c_str() + token.size() || !std::isfinite(val)) {
                throw std::runtime_error("number out of range");
            }
            return Json::make_number(val);
        }
        static bool is_digit(char c) { return c >= '0' && c <= '9'; }
    };
};

}  // namespace llm_provider
