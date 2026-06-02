defmodule Exbitnode.Messages.BlockHeaderCodec do
  @moduledoc false

  alias Exbitnode.Consensus.BlockHeader
  alias Exbitnode.Util.{CryptoUtil, Hex}
  alias Exbitnode.Wire.WireSerialize

  @serialized_size 80

  def serialized_size, do: @serialized_size

  def serialize(%BlockHeader{} = header) do
    WireSerialize.pack_int32_le(header.version) <>
      header.prev_block <>
      header.merkle_root <>
      WireSerialize.pack_int32_le(header.timestamp) <>
      WireSerialize.pack_int32_le(header.bits) <>
      WireSerialize.pack_int32_le(header.nonce)
  end

  def deserialize(data, offset \\ 0) when is_binary(data) do
    <<
      version::little-signed-32,
      prev_block::binary-size(32),
      merkle_root::binary-size(32),
      timestamp::little-signed-32,
      bits::little-unsigned-32,
      nonce::little-unsigned-32,
      _rest::binary
    >> = binary_part(data, offset, @serialized_size)

    {%BlockHeader{
       version: version,
       prev_block: prev_block,
       merkle_root: merkle_root,
       timestamp: timestamp,
       bits: bits,
       nonce: nonce
     }, offset + @serialized_size}
  end

  def block_hash(%BlockHeader{} = header) do
    header |> serialize() |> CryptoUtil.double_sha256()
  end

  def block_hash_hex(%BlockHeader{} = header) do
    header |> block_hash() |> Hex.reverse() |> Hex.encode()
  end
end
