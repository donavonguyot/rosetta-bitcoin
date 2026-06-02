#include "cpbitnode/consensus/subsidy.hpp"

#include "cpbitnode/consensus/constants.hpp"

namespace cpbitnode::consensus {

std::int64_t blockSubsidy(std::int32_t height) {
    if (height < 0) {
        return 0;
    }
    const auto halvings = height / kSubsidyHalvingInterval;
    if (halvings >= 64) {
        return 0;
    }
    return (50 * kCoin) >> halvings;
}

}  // namespace cpbitnode::consensus
