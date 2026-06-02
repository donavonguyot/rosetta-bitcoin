#pragma once

#include <map>
#include <string>
#include <vector>

namespace cpbitnode::wire {

struct WireCheckpoint {
    std::string id;
    std::string title;
    std::string description;
    std::string phase;
};

struct WireCapability {
    std::string id;
    std::string checkpoint;
    std::string category;
    std::string name;
    std::string description;
    bool required = false;
    bool implemented = false;
};

const std::vector<WireCheckpoint>& checkpoints();
const std::vector<WireCapability>& capabilities();

std::map<std::string, std::map<std::string, std::string>> checkpointStatus(
    const std::map<std::string, int>& capabilityMap);
std::map<std::string, std::string> fullNodeWireProgress(const std::map<std::string, int>& capabilityMap);

}  // namespace cpbitnode::wire
