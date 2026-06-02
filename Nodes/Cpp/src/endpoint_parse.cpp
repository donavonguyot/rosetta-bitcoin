#include "cpbitnode/endpoint_parse.hpp"

#include <cctype>
#include <sstream>

namespace cpbitnode {

bool isValidListenPort(int port) { return port >= 1 && port <= 65535; }

bool hostPortIsWellFormedEndpoint(const std::string& host, int port) {
    if (host.empty() || !isValidListenPort(port)) {
        return false;
    }
    std::string candidate = host;
    if (!candidate.empty() && candidate.front() == '[' && candidate.back() == ']') {
        candidate = candidate.substr(1, candidate.size() - 2);
    }
    bool allDigit = !candidate.empty();
    for (char c : candidate) {
        if (!std::isdigit(static_cast<unsigned char>(c)) && c != '.' && c != ':') {
            allDigit = false;
            break;
        }
    }
    if (allDigit && candidate.find('.') != std::string::npos) {
        return true;
    }
    if (candidate.find(':') != std::string::npos && candidate.find('.') == std::string::npos) {
        for (char c : candidate) {
            if (std::isxdigit(static_cast<unsigned char>(c)) || c == ':') {
                continue;
            }
            return false;
        }
        if (candidate.rfind("::ffff:", 0) == 0) {
            return candidate.substr(7).find('.') != std::string::npos;
        }
        return true;
    }
    for (char c : candidate) {
        if (std::isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '.') {
            continue;
        }
        return false;
    }
    return true;
}

std::optional<std::pair<std::string, int>> normalizePeerManualSpec(const std::string& raw, int defaultPort) {
    const std::string item = [&]() {
        std::string s = raw;
        const auto start = s.find_first_not_of(" \t");
        const auto end = s.find_last_not_of(" \t");
        if (start == std::string::npos) {
            return std::string{};
        }
        return s.substr(start, end - start + 1);
    }();
    if (item.empty()) {
        return std::nullopt;
    }
    std::string host;
    int port = defaultPort;
    if (item.front() == '[') {
        const auto end = item.find(']');
        if (end == std::string::npos) {
            return std::nullopt;
        }
        host = item.substr(1, end - 1);
        const std::string rest = item.substr(end + 1);
        if (rest.empty()) {
            port = defaultPort;
        } else if (rest.front() == ':') {
            port = std::stoi(rest.substr(1));
        } else {
            return std::nullopt;
        }
    } else if (item.find(':') != std::string::npos) {
        const auto colon = item.rfind(':');
        host = item.substr(0, colon);
        port = std::stoi(item.substr(colon + 1));
    } else {
        host = item;
    }
    if (!hostPortIsWellFormedEndpoint(host, port)) {
        return std::nullopt;
    }
    return std::make_pair(host, port);
}

std::vector<std::pair<std::string, int>> splitManualPeerList(const std::string& raw, int defaultPort) {
    std::vector<std::pair<std::string, int>> out;
    std::stringstream ss(raw);
    std::string fragment;
    while (std::getline(ss, fragment, ',')) {
        if (const auto ep = normalizePeerManualSpec(fragment, defaultPort)) {
            out.push_back(*ep);
        }
    }
    return out;
}

}  // namespace cpbitnode
