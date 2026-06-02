defmodule Exbitnode.Messages.HandshakeMessages do
  @moduledoc false

  import Bitwise

  alias Exbitnode.Wire.WireSerialize

  @version_command "version"
  @verack_command "verack"
  @sendheaders_command "sendheaders"

  def version_command, do: @version_command
  def verack_command, do: @verack_command
  def sendheaders_command, do: @sendheaders_command

  def node_network, do: 1
  def node_witness, do: 1 <<< 3

  defmodule VersionMessage do
    @moduledoc false
    defstruct [
      :version,
      :services,
      :timestamp,
      :addr_recv,
      :addr_from,
      :nonce,
      :user_agent,
      :start_height,
      :relay
    ]
  end

  def serialize_version(%VersionMessage{} = msg) do
    payload =
      WireSerialize.pack_int32_le(msg.version) <>
        WireSerialize.pack_int64_le(msg.services) <>
        WireSerialize.pack_int64_le(msg.timestamp) <>
        serialize_network_address(msg.addr_recv) <>
        serialize_network_address(msg.addr_from) <>
        WireSerialize.pack_int64_le(msg.nonce)

    ua = msg.user_agent

    payload =
      payload <>
        WireSerialize.write_compact_size(byte_size(ua)) <>
        ua <>
        WireSerialize.pack_int32_le(msg.start_height)

    if msg.version >= 70_002 do
      payload <> if(msg.relay, do: <<1>>, else: <<0>>)
    else
      payload
    end
  end

  def deserialize_version(payload) when is_binary(payload) do
    offset = 0

    version = WireSerialize.unpack_int32_le(payload, offset)
    offset = offset + 4
    services = WireSerialize.unpack_int64_le(payload, offset)
    offset = offset + 8
    timestamp = WireSerialize.unpack_int64_le(payload, offset)
    offset = offset + 8

    {addr_recv, offset} = deserialize_network_address(payload, offset)
    {addr_from, offset} = deserialize_network_address(payload, offset)

    nonce = WireSerialize.unpack_int64_le(payload, offset)
    offset = offset + 8

    {ua_len, ua_read} = WireSerialize.read_compact_size_at(payload, offset)
    offset = offset + ua_read
    user_agent = binary_part(payload, offset, ua_len)
    offset = offset + ua_len

    start_height = WireSerialize.unpack_int32_le(payload, offset)
    offset = offset + 4

    relay =
      if version < 70_002 do
        true
      else
        offset < byte_size(payload) and :binary.at(payload, offset) != 0
      end

    %VersionMessage{
      version: version,
      services: services,
      timestamp: timestamp,
      addr_recv: addr_recv,
      addr_from: addr_from,
      nonce: nonce,
      user_agent: user_agent,
      start_height: start_height,
      relay: relay
    }
  end

  def serialize_verack, do: <<>>
  def serialize_sendheaders, do: <<>>

  defp serialize_network_address(%{services: services, ip: ip, port: port}) do
    WireSerialize.pack_int64_le(services) <> ip <> WireSerialize.pack_uint16_be(port)
  end

  defp deserialize_network_address(data, offset) do
    services = WireSerialize.unpack_int64_le(data, offset)
    offset = offset + 8
    ip = binary_part(data, offset, 16)
    offset = offset + 16
    port = WireSerialize.unpack_uint16_be(data, offset)
    offset = offset + 2
    {%{services: services, ip: ip, port: port}, offset}
  end

  def encode_loopback_address(port) do
    ip = <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 127, 0, 0, 1>>
    %{services: node_network() ||| node_witness(), ip: ip, port: port}
  end
end
