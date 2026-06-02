defmodule Exbitnode.Wire.MessageFramer do
  @moduledoc false

  alias Exbitnode.Wire.WireSerialize

  @header_size 24

  def header_size, do: @header_size

  def parse_header(data) when byte_size(data) >= @header_size do
    <<magic::binary-size(4), command_raw::binary-size(12), length::little-signed-32,
      checksum::binary-size(4), _rest::binary>> = data

    command = command_raw |> :binary.bin_to_list() |> Enum.take_while(&(&1 != 0)) |> List.to_string()

    %{
      magic: magic,
      command: command,
      length: length,
      checksum: checksum
    }
  end

  def parse_header(data) do
    raise ArgumentError, "header requires #{@header_size} bytes, got #{byte_size(data)}"
  end

  def header_to_bytes(%{magic: magic, command: command, length: length, checksum: checksum}) do
    cmd = command |> String.slice(0, 12) |> String.pad_trailing(12, <<0>>)
    magic <> cmd <> WireSerialize.pack_int32_le(length) <> checksum
  end

  def build_message(magic, command, payload) when is_binary(payload) do
    checksum = WireSerialize.message_checksum(payload)

    header =
      header_to_bytes(%{
        magic: magic,
        command: command,
        length: byte_size(payload),
        checksum: checksum
      })

    header <> payload
  end

  def verify_checksum(payload, checksum) when is_binary(payload) and is_binary(checksum) do
    WireSerialize.message_checksum(payload) == checksum
  end
end
