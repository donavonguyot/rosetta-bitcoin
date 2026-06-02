#include "cpbitnode/p2p/discovery.hpp"

#include "cpbitnode/endpoint_parse.hpp"

#include <algorithm>
#include <netdb.h>
#include <random>
#include <set>
#include <stdexcept>

namespace cpbitnode::p2p {
namespace {

bool isRoutable(const std::string& host, int port) {
    if (!hostPortIsWellFormedEndpoint(host, port)) {
        return false;
    }
    if (host == "0.0.0.0" || host == "::" || host == "127.0.0.1" || host == "::1") {
        return false;
    }
    if (host.rfind("127.", 0) == 0) {
        return false;
    }
    return true;
}

}  // namespace

std::vector<std::pair<std::string, int>> resolveSeedPeers(const chain::ChainParams& chain, int count) {
    std::vector<std::pair<std::string, int>> peers;
    std::set<std::pair<std::string, int>> seen;
    if (chain.dnsSeeds.empty()) {
        return peers;
    }
    std::vector<std::string> seeds = chain.dnsSeeds;
    std::shuffle(seeds.begin(), seeds.end(), std::mt19937{std::random_device{}()});

    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    for (const auto& seed : seeds) {
        addrinfo* result = nullptr;
        const std::string portStr = std::to_string(chain.defaultPort);
        if (::getaddrinfo(seed.c_str(), portStr.c_str(), &hints, &result) != 0) {
            continue;
        }
        for (addrinfo* rp = result; rp != nullptr; rp = rp->ai_next) {
            char hostBuf[NI_MAXHOST] = {};
            if (::getnameinfo(rp->ai_addr, rp->ai_addrlen, hostBuf, sizeof(hostBuf), nullptr, 0, NI_NUMERICHOST) != 0) {
                continue;
            }
            const std::pair<std::string, int> item{hostBuf, chain.defaultPort};
            if (seen.insert(item).second) {
                peers.push_back(item);
            }
            if (static_cast<int>(peers.size()) >= count) {
                ::freeaddrinfo(result);
                return peers;
            }
        }
        ::freeaddrinfo(result);
    }
    return peers;
}

std::pair<std::string, int> resolveSeedFallback(const chain::ChainParams& chain) {
    const auto peers = resolveSeedPeers(chain, 1);
    if (peers.empty()) {
        throw std::runtime_error("No DNS seed peers resolved");
    }
    return peers.front();
}

std::vector<std::pair<std::string, int>> mergePeerCandidates(
    const chain::ChainParams& chain, const std::vector<std::pair<std::string, int>>& manual,
    const std::vector<std::pair<std::string, int>>& stored,
    const std::vector<std::pair<std::string, int>>& discovered,
    const std::vector<std::pair<std::string, int>>& seeds) {
    std::vector<std::pair<std::string, int>> merged;
    std::set<std::pair<std::string, int>> seen;
    const std::vector<std::pair<std::string, int>>* groups[] = {&manual, &stored, &discovered, &seeds};
    for (const auto* group : groups) {
        for (const auto& [host, port] : *group) {
            if (!isRoutable(host, port)) {
                continue;
            }
            const std::pair<std::string, int> item{host, port};
            if (seen.insert(item).second) {
                merged.push_back(item);
            }
        }
    }
    (void)chain;
    return merged;
}

std::vector<std::pair<std::string, int>> bootstrapPeerTargets(
    db::NodeStateStore& tracker, const chain::ChainParams& chain, const config::Settings& settings,
    const std::vector<std::pair<std::string, int>>& manualPeers, ResolveSeedPeersFn resolveSeeds) {
    const auto stored = tracker.listPeerAddressEndpoints(settings.maxOutboundPeers * 4);
    auto seeds = resolveSeeds(chain, settings.maxOutboundPeers);
    if (manualPeers.empty() && stored.empty() && seeds.empty()) {
        try {
            seeds = {resolveSeedFallback(chain)};
        } catch (const std::exception&) {
            seeds.clear();
        }
    }
    auto merged = mergePeerCandidates(chain, manualPeers, stored, {}, seeds);
    if (static_cast<int>(merged.size()) > settings.maxOutboundPeers * 2) {
        merged.resize(static_cast<std::size_t>(settings.maxOutboundPeers * 2));
    }

    const int threshold = settings.peerBanScoreThreshold;
    std::set<std::pair<std::string, int>> manualSet(manualPeers.begin(), manualPeers.end());
    std::vector<std::pair<std::string, int>> filtered;
    filtered.reserve(merged.size());
    for (const auto& target : merged) {
        if (manualSet.count(target) > 0 || tracker.getPeerEndpointBanScore(target.first, target.second) <= threshold) {
            filtered.push_back(target);
        }
    }
    return filtered;
}

}  // namespace cpbitnode::p2p
