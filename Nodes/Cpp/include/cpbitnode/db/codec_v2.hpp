#pragma once

#include "cpbitnode/db/node_state.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace cpbitnode::db::codec_v2 {

inline constexpr int kCodecVersion = 2;

std::string keyUtxo(const std::string& chain, const std::vector<std::uint8_t>& txid, int vout);
std::string keyUndo(const std::string& chain, int height);
std::string keyTip(const std::string& chain);
std::string keyMetadata(const std::string& name);
std::string keyBlockIndex(const std::string& chain, int height);
std::string keyHeader(const std::string& chain, int height);

std::string prefixUtxo(const std::string& chain);
std::string prefixUndo(const std::string& chain);
std::string prefixBlockIndex(const std::string& chain);
std::string prefixHeader(const std::string& chain);

std::string encodeUtxoValue(const StoredUtxo& utxo);
StoredUtxo decodeUtxoValue(const std::vector<std::uint8_t>& txid, int vout, const std::string& encoded);

std::string encodeUndoValue(const std::vector<StoredUtxo>& entries);
std::vector<StoredUtxo> decodeUndoValue(const std::string& encoded);

std::string encodeTipValue(int height, const std::vector<std::uint8_t>& blockHashInternal);
std::pair<int, std::vector<std::uint8_t>> decodeTipValue(const std::string& encoded);

std::string encodeBlockIndexValue(const std::vector<std::uint8_t>& blockHashInternal, int fileNumber, int fileOffset,
                                  int blockSize);
StoredBlockRow decodeBlockIndexValue(int height, const std::string& encoded);

std::string encodeHeaderValue(const std::vector<std::uint8_t>& serializedHeader);
std::vector<std::uint8_t> decodeHeaderValue(const std::string& encoded);

std::string encodeMetadataValue(const std::string& value);
std::string decodeMetadataValue(const std::string& encoded);

std::vector<std::uint8_t> hexToBytes(const std::string& hex);
std::string bytesToHex(const std::vector<std::uint8_t>& bytes);
std::string internalToDisplayHex(const std::vector<std::uint8_t>& bytes);
std::vector<std::uint8_t> displayHexToInternal(const std::string& hex);
int heightFromKey(const std::string& key);
int voutFromUtxoKey(const std::string& key);
std::vector<std::uint8_t> txidFromUtxoKey(const std::string& chain, const std::string& key);
bool selfTestGoldenVector();

}  // namespace cpbitnode::db::codec_v2
