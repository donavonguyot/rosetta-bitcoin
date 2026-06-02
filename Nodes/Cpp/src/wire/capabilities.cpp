#include "cpbitnode/wire/capabilities.hpp"

#include <cmath>
#include <sstream>

namespace cpbitnode::wire {

extern const std::vector<WireCheckpoint> kCheckpoints;
extern const std::vector<WireCapability> kCapabilities;

const std::vector<WireCheckpoint>& checkpoints() { return kCheckpoints; }
const std::vector<WireCapability>& capabilities() { return kCapabilities; }

std::map<std::string, std::map<std::string, std::string>> checkpointStatus(
    const std::map<std::string, int>& capabilityMap) {
    std::map<std::string, std::map<std::string, std::string>> result;
    for (const auto& cp : kCheckpoints) {
        int requiredTotal = 0;
        int requiredDone = 0;
        int optionalTotal = 0;
        int optionalDone = 0;
        int capabilitiesTotal = 0;
        int capabilitiesDone = 0;
        for (const auto& cap : kCapabilities) {
            if (cap.checkpoint != cp.id) {
                continue;
            }
            ++capabilitiesTotal;
            const int done = capabilityMap.count(cap.id) ? capabilityMap.at(cap.id) : 0;
            if (done == 1) {
                ++capabilitiesDone;
            }
            if (cap.required) {
                ++requiredTotal;
                if (done == 1) {
                    ++requiredDone;
                }
            } else {
                ++optionalTotal;
                if (done == 1) {
                    ++optionalDone;
                }
            }
        }
        const bool requiredPass = requiredTotal == 0 || requiredDone == requiredTotal;
        result[cp.id] = {
            {"checkpoint", cp.id},
            {"title", cp.title},
            {"phase", cp.phase},
            {"required_total", std::to_string(requiredTotal)},
            {"required_done", std::to_string(requiredDone)},
            {"required_pass", requiredPass ? "true" : "false"},
            {"optional_total", std::to_string(optionalTotal)},
            {"optional_done", std::to_string(optionalDone)},
            {"capabilities_total", std::to_string(capabilitiesTotal)},
            {"capabilities_done", std::to_string(capabilitiesDone)},
        };
    }
    return result;
}

std::map<std::string, std::string> fullNodeWireProgress(const std::map<std::string, int>& capabilityMap) {
    int requiredTotal = 0;
    int requiredDone = 0;
    for (const auto& cap : kCapabilities) {
        if (!cap.required) {
            continue;
        }
        ++requiredTotal;
        const int done = capabilityMap.count(cap.id) ? capabilityMap.at(cap.id) : 0;
        if (done == 1) {
            ++requiredDone;
        }
    }
    const auto checkpoints = checkpointStatus(capabilityMap);
    int checkpointsPassed = 0;
    for (const auto& [_, row] : checkpoints) {
        if (row.at("required_pass") == "true") {
            ++checkpointsPassed;
        }
    }
    std::ostringstream reqPct;
    reqPct << std::fixed;
    reqPct.precision(1);
    reqPct << (requiredTotal ? (100.0 * requiredDone / requiredTotal) : 100.0);
    std::ostringstream cpPct;
    cpPct << std::fixed;
    cpPct.precision(1);
    cpPct << (kCheckpoints.empty() ? 100.0 : (100.0 * checkpointsPassed / kCheckpoints.size()));

    return {
        {"required_total", std::to_string(requiredTotal)},
        {"required_done", std::to_string(requiredDone)},
        {"required_percent", reqPct.str()},
        {"checkpoints_total", std::to_string(kCheckpoints.size())},
        {"checkpoints_passed", std::to_string(checkpointsPassed)},
        {"checkpoints_percent", cpPct.str()},
        {"full_node_wire_ready", (requiredDone == requiredTotal) ? "true" : "false"},
    };
}

}  // namespace cpbitnode::wire
