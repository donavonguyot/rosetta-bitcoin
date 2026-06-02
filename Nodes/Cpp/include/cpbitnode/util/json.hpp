#pragma once

#include <map>
#include <string>
#include <vector>

namespace cpbitnode::util {

std::string escapeJson(const std::string& s);
std::string jsonString(const std::string& s);
std::string jsonObject(const std::map<std::string, std::string>& fields);
std::string jsonArray(const std::vector<std::string>& items);

}  // namespace cpbitnode::util
