defmodule Exbitnode.Messages.HeadersMessage do
  @moduledoc false

  alias Exbitnode.Consensus.BlockHeader
  alias Exbitnode.Messages.BlockHeaderCodec
  alias Exbitnode.Wire.WireSerialize

  @command "headers"
  @getheaders_command "getheaders"

  def command, do: @command
  def getheaders_command, do: @getheaders_command

  def serialize_getheaders(protocol_version, locator, stop_hash)
      when is_list(locator) and is_binary(stop_hash) do
    payload =
      WireSerialize.pack_int32_le(protocol_version) <>
        WireSerialize.write_compact_size(length(locator))

    locator_payload = Enum.reduce(locator, <<>>, fn hash, acc -> acc <> hash end)

    payload <> locator_payload <> stop_hash
  end

  def deserialize(payload) when is_binary(payload) do
    {count, read} = WireSerialize.read_compact_size_at(payload, 0)
    offset = read
    {headers, offset} = deserialize_headers(payload, offset, count, [])

    if offset != byte_size(payload) do
      :ok
    end

    headers
  end

  defp deserialize_headers(_payload, offset, 0, acc), do: {Enum.reverse(acc), offset}

  defp deserialize_headers(payload, offset, remaining, acc) do
    {%BlockHeader{} = header, offset} = BlockHeaderCodec.deserialize(payload, offset)
    {tx_count, tx_read} = WireSerialize.read_compact_size_at(payload, offset)
    offset = offset + tx_read

    if tx_count != 0 do
      raise ArgumentError, "headers message must have tx_count=0 per header"
    end

    deserialize_headers(payload, offset, remaining - 1, [header | acc])
  end
end
