#include "cpbitnode/mempool/prevout.hpp"

namespace cpbitnode::mempool {

PrevoutKey inputPrevoutKey(const messages::TxIn& input) {
    return {input.previousOutput.hash, static_cast<int>(input.previousOutput.index)};
}

}  // namespace cpbitnode::mempool
