defmodule Exbitnode.Wire.WireSerialize do
  @moduledoc false

  alias Exbitnode.Util.CryptoUtil

  def double_sha256(data), do: CryptoUtil.double_sha256(data)
  def message_checksum(payload), do: CryptoUtil.message_checksum(payload)

  def pack_int32_le(value) when is_integer(value), do: <<value::little-signed-32>>
  def pack_int64_le(value) when is_integer(value), do: <<value::little-signed-64>>
  def pack_uint16_be(value) when is_integer(value), do: <<value::unsigned-big-16>>

  def unpack_int32_le(data, offset) when is_binary(data) and is_integer(offset) do
    <<value::little-signed-32, _rest::binary>> = binary_part(data, offset, 4)
    value
  end

  def unpack_int64_le(data, offset) when is_binary(data) and is_integer(offset) do
    <<value::little-signed-64, _rest::binary>> = binary_part(data, offset, 8)
    value
  end

  def unpack_uint16_be(data, offset) when is_binary(data) and is_integer(offset) do
    <<value::unsigned-big-16, _rest::binary>> = binary_part(data, offset, 2)
    value
  end

  def write_compact_size(value) when value < 0xFD, do: <<value>>
  def write_compact_size(value) when value <= 0xFFFF, do: <<0xFD, value::little-unsigned-16>>

  def write_compact_size(value) when value <= 0xFFFF_FFFF do
    <<0xFE>> <> pack_int32_le(value)
  end

  def write_compact_size(value), do: <<0xFF>> <> pack_int64_le(value)

  def read_compact_size_at(data, offset) when is_binary(data) and is_integer(offset) do
    read_compact_size_chunk(binary_part(data, offset, byte_size(data) - offset))
  end

  defp read_compact_size_chunk(<<first, rest::binary>>) do
    case first do
      n when n < 0xFD ->
        {n, 1}

      0xFD ->
        <<value::little-unsigned-16, _rest2::binary>> = rest
        {value, 3}

      0xFE ->
        <<value::little-unsigned-32, _rest2::binary>> = rest
        {value, 5}

      0xFF ->
        <<value::little-signed-64, _rest2::binary>> = rest
        {value, 9}
    end
  end

  def read_bytes(data, count, offset)
      when is_binary(data) and is_integer(count) and is_integer(offset) do
    {binary_part(data, offset, count), offset + count}
  end
end
