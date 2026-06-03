defmodule Exbitnode.Db.ChainstateCodecV2 do
  @moduledoc false

  alias Exbitnode.Util.Hex

  @utxo_prefix 0x75
  @undo_prefix 0x64
  @tip_prefix 0x74
  @metadata_prefix 0x6D
  @block_index_prefix 0x62
  @header_prefix 0x68
  @event_prefix 0x65
  @blocker_prefix 0x78
  @sync_state_prefix 0x73
  @peer_prefix 0x70

  def codec_version, do: "2"

  def utxo_key(chain, txid_internal, vout),
    do: <<@utxo_prefix>> <> chain_key(chain) <> txid_internal <> u32(vout)

  def undo_key(chain, height), do: <<@undo_prefix>> <> chain_key(chain) <> u32(height)
  def tip_key(chain), do: <<@tip_prefix>> <> chain_key(chain)
  def metadata_key(name), do: <<@metadata_prefix>> <> length_prefixed_string(name)
  def sync_state_key(chain), do: <<@sync_state_prefix>> <> chain_key(chain)
  def peer_key(id), do: <<@peer_prefix, id::unsigned-big-64>>

  def block_index_key(chain, height),
    do: <<@block_index_prefix>> <> chain_key(chain) <> u32(height)

  def header_key(chain, height), do: <<@header_prefix>> <> chain_key(chain) <> u32(height)
  def event_key(id), do: <<@event_prefix, id::unsigned-big-64>>
  def blocker_key(chain), do: <<@blocker_prefix>> <> chain_key(chain)

  def utxo_prefix(chain), do: <<@utxo_prefix>> <> chain_key(chain)
  def undo_prefix(chain), do: <<@undo_prefix>> <> chain_key(chain)
  def block_index_prefix(chain), do: <<@block_index_prefix>> <> chain_key(chain)
  def header_prefix(chain), do: <<@header_prefix>> <> chain_key(chain)
  def event_prefix, do: <<@event_prefix>>
  def peer_prefix, do: <<@peer_prefix>>

  def encode_utxo(%{height: height, value_sats: value_sats, script_pubkey_hex: script_hex} = utxo) do
    script = Hex.decode(script_hex)

    <<height::unsigned-big-32, value_sats::unsigned-big-64, flags(utxo)::unsigned-big-8>> <>
      varbytes(script)
  end

  def decode_utxo(
        txid,
        vout,
        <<height::unsigned-big-32, value_sats::unsigned-big-64, flags::unsigned-big-8,
          rest::binary>>
      ) do
    {script, <<>>} = read_varbytes(rest)

    %{
      txid: txid,
      vout: vout,
      height: height,
      value_sats: value_sats,
      script_pubkey_hex: Hex.encode(script),
      coinbase: Bitwise.band(flags, 1) == 1
    }
  end

  def encode_undo(entries) when is_list(entries) do
    body =
      Enum.map(entries, fn entry ->
        txid_internal = entry.txid |> Hex.decode() |> Hex.reverse()
        script = Hex.decode(entry.script_pubkey_hex)

        txid_internal <>
          u32(entry.vout) <>
          u32(Map.get(entry, :utxo_height, Map.get(entry, :height, 0))) <>
          u64(entry.value_sats) <>
          <<flags(entry)>> <>
          varbytes(script)
      end)
      |> IO.iodata_to_binary()

    u32(length(entries)) <> body
  end

  def decode_undo(<<count::unsigned-big-32, rest::binary>>) do
    {entries, <<>>} =
      Enum.reduce(1..count//1, {[], rest}, fn _, {acc, bytes} ->
        <<txid_internal::binary-size(32), vout::unsigned-big-32, height::unsigned-big-32,
          value_sats::unsigned-big-64, flags::unsigned-big-8, tail::binary>> = bytes

        {script, tail} = read_varbytes(tail)

        entry = %{
          txid: txid_internal |> Hex.reverse() |> Hex.encode(),
          vout: vout,
          utxo_height: height,
          value_sats: value_sats,
          script_pubkey_hex: Hex.encode(script),
          coinbase: Bitwise.band(flags, 1) == 1
        }

        {[entry | acc], tail}
      end)

    Enum.reverse(entries)
  end

  def encode_tip(height, block_hash_hex) do
    block_hash_internal = block_hash_hex |> Hex.decode() |> Hex.reverse()
    u32(height) <> block_hash_internal
  end

  def decode_tip(<<height::unsigned-big-32, block_hash_internal::binary-size(32)>>) do
    %{height: height, block_hash: block_hash_internal |> Hex.reverse() |> Hex.encode()}
  end

  def encode_block_index(%{
        block_hash: block_hash,
        file_number: file_number,
        file_offset: file_offset,
        block_size: block_size
      }) do
    block_hash_internal = block_hash |> Hex.decode() |> Hex.reverse()
    block_hash_internal <> u32(file_number) <> u32(file_offset) <> u32(block_size)
  end

  def decode_block_index(
        chain,
        height,
        <<hash_internal::binary-size(32), file_number::unsigned-big-32,
          file_offset::unsigned-big-32, block_size::unsigned-big-32>>
      ) do
    %{
      chain: chain,
      height: height,
      block_hash: hash_internal |> Hex.reverse() |> Hex.encode(),
      file_number: file_number,
      file_offset: file_offset,
      block_size: block_size
    }
  end

  def encode_header(serialized_header), do: varbytes(serialized_header)

  def decode_header(bytes) do
    {header, <<>>} = read_varbytes(bytes)
    header
  end

  defp chain_key(chain), do: length_prefixed_string(chain)

  defp length_prefixed_string(value) when is_binary(value) and byte_size(value) <= 255 do
    <<byte_size(value)::unsigned-big-8, value::binary>>
  end

  defp varbytes(bytes), do: u32(byte_size(bytes)) <> bytes

  defp read_varbytes(<<len::unsigned-big-32, rest::binary>>) do
    <<value::binary-size(len), tail::binary>> = rest
    {value, tail}
  end

  defp flags(value), do: if(Map.get(value, :coinbase, false), do: 1, else: 0)
  defp u32(value), do: <<value::unsigned-big-32>>
  defp u64(value), do: <<value::unsigned-big-64>>
end
