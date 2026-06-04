package com.jbitnode.db;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.jbitnode.db.ProjectTracker.StoredUtxo;
import com.jbitnode.db.ProjectTracker.UtxoUndoEntry;
import com.jbitnode.util.Hex;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;

class NativeChainstateCodecV2Test {

  @Test
  void matchesSharedGoldenVectors() throws Exception {
    JsonNode vectors =
        new ObjectMapper()
            .readTree(
                Files.readString(
                    Path.of(
                        "..",
                        "Shared",
                        "conformance",
                        "fixtures",
                        "chainstate_codec_v2_vectors.json")));
    String chain = vectors.get("chain").asText();
    String txid = vectors.get("txid_internal_hex").asText();
    String blockHash = vectors.get("block_hash_internal_hex").asText();
    String script = vectors.get("script_pubkey_hex").asText();

    JsonNode utxo = vectors.get("utxo");
    StoredUtxo storedUtxo =
        new StoredUtxo(
            Hex.decode(txid),
            utxo.get("vout").asInt(),
            utxo.get("height").asInt(),
            utxo.get("value_sats").asLong(),
            Hex.decode(script),
            utxo.get("coinbase").asBoolean());
    assertEquals(
        utxo.get("key_hex").asText(),
        Hex.encode(NativeChainstateCodec.utxoKeyV2(chain, txid, utxo.get("vout").asInt())));
    assertEquals(utxo.get("value_hex").asText(), Hex.encode(NativeChainstateCodec.encodeUtxoV2(storedUtxo)));

    JsonNode undo = vectors.get("undo");
    UtxoUndoEntry undoEntry =
        new UtxoUndoEntry(
            Hex.decode(txid),
            utxo.get("vout").asInt(),
            utxo.get("height").asInt(),
            utxo.get("value_sats").asLong(),
            Hex.decode(script),
            utxo.get("coinbase").asBoolean());
    assertEquals(
        undo.get("key_hex").asText(),
        Hex.encode(NativeChainstateCodec.undoKeyV2(chain, undo.get("height").asInt())));
    assertEquals(
        undo.get("value_hex").asText(),
        Hex.encode(NativeChainstateCodec.encodeUndoV2(List.of(undoEntry))));

    JsonNode tip = vectors.get("tip");
    assertEquals(tip.get("key_hex").asText(), Hex.encode(NativeChainstateCodec.tipKeyV2(chain)));
    assertEquals(
        tip.get("value_hex").asText(),
        Hex.encode(NativeChainstateCodec.encodeTipV2(new ChainstateTip(tip.get("height").asInt(), blockHash))));

    JsonNode blockIndex = vectors.get("block_index");
    assertEquals(
        blockIndex.get("key_hex").asText(),
        Hex.encode(NativeChainstateCodec.blockIndexKeyV2(chain, blockIndex.get("height").asInt())));
    assertEquals(
        blockIndex.get("value_hex").asText(),
        Hex.encode(
            NativeChainstateCodec.encodeBlockIndexV2(
                blockHash,
                blockIndex.get("file_number").asInt(),
                blockIndex.get("file_offset").asInt(),
                blockIndex.get("block_size").asInt())));

    JsonNode header = vectors.get("header");
    assertEquals(
        header.get("key_hex").asText(),
        Hex.encode(NativeChainstateCodec.headerKeyV2(chain, header.get("height").asInt())));
    assertEquals(
        header.get("value_hex").asText(),
        Hex.encode(NativeChainstateCodec.encodeHeaderV2(Hex.decode(header.get("serialized_header_hex").asText()))));

    JsonNode metadata = vectors.get("metadata");
    assertEquals(
        metadata.get("key_hex").asText(),
        Hex.encode(NativeChainstateCodec.metadataKeyV2(metadata.get("name").asText())));
    assertEquals(metadata.get("value_hex").asText(), Hex.encode(NativeChainstateCodec.metadataValue(metadata.get("value").asText())));
  }
}
