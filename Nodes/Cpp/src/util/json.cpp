#include "cpbitnode/util/json.hpp"

namespace cpbitnode::util {

std::string escapeJson(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (const char c : s) {
        switch (c) {
            case '"':
                out += "\\\"";
                break;
            case '\\':
                out += "\\\\";
                break;
            case '\b':
                out += "\\b";
                break;
            case '\f':
                out += "\\f";
                break;
            case '\n':
                out += "\\n";
                break;
            case '\r':
                out += "\\r";
                break;
            case '\t':
                out += "\\t";
                break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    out += "\\u00";
                    out.push_back("0123456789abcdef"[(c >> 4) & 0xf]);
                    out.push_back("0123456789abcdef"[c & 0xf]);
                } else {
                    out.push_back(c);
                }
        }
    }
    return out;
}

std::string jsonString(const std::string& s) { return "\"" + escapeJson(s) + "\""; }

std::string jsonObject(const std::map<std::string, std::string>& fields) {
    std::string out = "{";
    bool first = true;
    for (const auto& [k, v] : fields) {
        if (!first) {
            out += ",";
        }
        first = false;
        out += jsonString(k) + ":" + v;
    }
    out += "}";
    return out;
}

std::string jsonArray(const std::vector<std::string>& items) {
    std::string out = "[";
    for (std::size_t i = 0; i < items.size(); ++i) {
        if (i > 0) {
            out += ",";
        }
        out += jsonString(items[i]);
    }
    out += "]";
    return out;
}

}  // namespace cpbitnode::util
