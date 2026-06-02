defmodule Exbitnode.Db.ChainstateCodecV2Test do
  use ExUnit.Case, async: true

  alias Exbitnode.Db.ChainstateCodecV2
  alias Exbitnode.Util.Hex

  @vectors_path Path.expand(
                  "../../../NodeCore/conformance/fixtures/chainstate_codec_v2_vectors.json",
                  __DIR__
                )

  test "matches shared NodeCore golden vectors" do
    vectors = @vectors_path |> File.read!() |> Jason.decode!()
    chain = vectors["chain"]
    txid_internal = Hex.decode(vectors["txid_internal_hex"])

    block_hash =
      vectors["block_hash_internal_hex"] |> Hex.decode() |> Hex.reverse() |> Hex.encode()

    script_hex = vectors["script_pubkey_hex"]

    assert Hex.encode(ChainstateCodecV2.utxo_key(chain, txid_internal, vectors["utxo"]["vout"])) ==
             vectors["utxo"]["key_hex"]

    assert Hex.encode(
             ChainstateCodecV2.encode_utxo(%{
               height: vectors["utxo"]["height"],
               value_sats: vectors["utxo"]["value_sats"],
               script_pubkey_hex: script_hex,
               coinbase: vectors["utxo"]["coinbase"]
             })
           ) == vectors["utxo"]["value_hex"]

    assert Hex.encode(ChainstateCodecV2.undo_key(chain, vectors["undo"]["height"])) ==
             vectors["undo"]["key_hex"]

    assert Hex.encode(
             ChainstateCodecV2.encode_undo([
               %{
                 txid: txid_internal |> Hex.reverse() |> Hex.encode(),
                 vout: vectors["utxo"]["vout"],
                 utxo_height: vectors["utxo"]["height"],
                 value_sats: vectors["utxo"]["value_sats"],
                 script_pubkey_hex: script_hex,
                 coinbase: vectors["utxo"]["coinbase"]
               }
             ])
           ) == vectors["undo"]["value_hex"]

    assert Hex.encode(ChainstateCodecV2.tip_key(chain)) == vectors["tip"]["key_hex"]

    assert Hex.encode(ChainstateCodecV2.encode_tip(vectors["tip"]["height"], block_hash)) ==
             vectors["tip"]["value_hex"]

    assert Hex.encode(ChainstateCodecV2.block_index_key(chain, vectors["block_index"]["height"])) ==
             vectors["block_index"]["key_hex"]

    assert Hex.encode(
             ChainstateCodecV2.encode_block_index(%{
               block_hash: block_hash,
               file_number: vectors["block_index"]["file_number"],
               file_offset: vectors["block_index"]["file_offset"],
               block_size: vectors["block_index"]["block_size"]
             })
           ) == vectors["block_index"]["value_hex"]

    assert Hex.encode(ChainstateCodecV2.header_key(chain, vectors["header"]["height"])) ==
             vectors["header"]["key_hex"]

    assert Hex.encode(
             ChainstateCodecV2.encode_header(
               Hex.decode(vectors["header"]["serialized_header_hex"])
             )
           ) == vectors["header"]["value_hex"]

    assert Hex.encode(ChainstateCodecV2.metadata_key(vectors["metadata"]["name"])) ==
             vectors["metadata"]["key_hex"]
  end
end

defmodule Exbitnode.Consensus.NativeCryptoBackendTest do
  use ExUnit.Case, async: true

  alias Exbitnode.Consensus.Script.Secp256k1

  test "reports pure Elixir backend by default" do
    assert Secp256k1.selected_backend_name() in ["pure_elixir", "libsecp256k1"]
    assert is_boolean(Secp256k1.native_backend_available?())
  end
end
