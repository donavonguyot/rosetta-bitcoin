#pragma once

#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace cpbitnode {

bool isValidListenPort(int port);
bool hostPortIsWellFormedEndpoint(const std::string& host, int port);
std::optional<std::pair<std::string, int>> normalizePeerManualSpec(const std::string& raw, int defaultPort);
std::vector<std::pair<std::string, int>> splitManualPeerList(const std::string& raw, int defaultPort);

}  // namespace cpbitnode
