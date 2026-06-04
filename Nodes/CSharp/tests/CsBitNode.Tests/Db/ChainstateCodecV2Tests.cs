using System.Text.Json;
using CsBitNode.Db;
using CsBitNode.Util;

namespace CsBitNode.Tests.Db;

public class ChainstateCodecV2Tests
{
    [Fact]
    public void MatchesSharedGoldenVectors()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "Shared", "conformance", "fixtures", "chainstate_codec_v2_vectors.json"))));
        var root = doc.RootElement;
        var chain = root.GetProperty("chain").GetString()!;
        var txid = root.GetProperty("txid_internal_hex").GetString()!;
        var blockHash = root.GetProperty("block_hash_internal_hex").GetString()!;
        var script = root.GetProperty("script_pubkey_hex").GetString()!;

        var utxo = root.GetProperty("utxo");
        var stored = new StoredUtxo(
            txid,
            utxo.GetProperty("vout").GetInt32(),
            utxo.GetProperty("height").GetInt32(),
            utxo.GetProperty("value_sats").GetInt64(),
            script,
            utxo.GetProperty("coinbase").GetBoolean());
        Assert.Equal(utxo.GetProperty("key_hex").GetString(), Hex.Encode(ChainstateCodecV2.UtxoKey(chain, txid, stored.Vout)));
        Assert.Equal(utxo.GetProperty("value_hex").GetString(), Hex.Encode(ChainstateCodecV2.EncodeUtxo(stored)));

        var undo = root.GetProperty("undo");
        var undoEntry = new UtxoUndoEntry(txid, stored.Vout, stored.Height, stored.ValueSats, script, stored.Coinbase);
        Assert.Equal(undo.GetProperty("key_hex").GetString(), Hex.Encode(ChainstateCodecV2.UndoKey(chain, undo.GetProperty("height").GetInt32())));
        Assert.Equal(undo.GetProperty("value_hex").GetString(), Hex.Encode(ChainstateCodecV2.EncodeUndo([undoEntry])));

        var tip = root.GetProperty("tip");
        Assert.Equal(tip.GetProperty("key_hex").GetString(), Hex.Encode(ChainstateCodecV2.TipKey(chain)));
        Assert.Equal(tip.GetProperty("value_hex").GetString(), Hex.Encode(ChainstateCodecV2.EncodeTip(tip.GetProperty("height").GetInt32(), blockHash)));

        var blockIndex = root.GetProperty("block_index");
        Assert.Equal(blockIndex.GetProperty("key_hex").GetString(), Hex.Encode(ChainstateCodecV2.BlockIndexKey(chain, blockIndex.GetProperty("height").GetInt32())));
        Assert.Equal(
            blockIndex.GetProperty("value_hex").GetString(),
            Hex.Encode(ChainstateCodecV2.EncodeBlockIndex(
                blockHash,
                blockIndex.GetProperty("file_number").GetInt32(),
                blockIndex.GetProperty("file_offset").GetInt32(),
                blockIndex.GetProperty("block_size").GetInt32())));

        var header = root.GetProperty("header");
        Assert.Equal(header.GetProperty("key_hex").GetString(), Hex.Encode(ChainstateCodecV2.HeaderKey(chain, header.GetProperty("height").GetInt32())));
        Assert.Equal(header.GetProperty("value_hex").GetString(), Hex.Encode(ChainstateCodecV2.EncodeHeader(Hex.Decode(header.GetProperty("serialized_header_hex").GetString()!))));

        var metadata = root.GetProperty("metadata");
        Assert.Equal(metadata.GetProperty("key_hex").GetString(), Hex.Encode(ChainstateCodecV2.MetadataKey(metadata.GetProperty("name").GetString()!)));
        Assert.Equal(metadata.GetProperty("value_hex").GetString(), Hex.Encode(ChainstateCodecV2.MetadataValue(metadata.GetProperty("value").GetString()!)));
    }
}
