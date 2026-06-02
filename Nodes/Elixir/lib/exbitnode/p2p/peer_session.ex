defmodule Exbitnode.P2p.PeerSession do
  @moduledoc false

  import Bitwise

  alias Exbitnode.Messages.{BlockMessage, HandshakeMessages, HeadersMessage, InventoryMessages}
  alias Exbitnode.Wire.MessageStream

  defstruct [
    :host,
    :port,
    :chain,
    :conn,
    :socket,
    :stream,
    :remote_version,
    :start_height
  ]

  def connect(host, port, chain, conn, start_height) do
    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, active: false, packet: 0],
           30_000
         ) do
      {:ok, socket} ->
        stream = MessageStream.new(socket, chain.magic)

        case handshake_as_initiator(%__MODULE__{
               host: host,
               port: port,
               chain: chain,
               conn: conn,
               socket: socket,
               stream: stream,
               start_height: start_height
             }) do
          {:ok, session} ->
            record_peer(session)
            {:ok, session}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def close(%__MODULE__{socket: socket}) when not is_nil(socket) do
    :gen_tcp.close(socket)
    :ok
  end

  def close(_), do: :ok

  def request_headers(%__MODULE__{} = session, locator) do
    payload =
      HeadersMessage.serialize_getheaders(session.chain.protocol_version, locator, <<0::256>>)

    with {:ok, stream} <-
           MessageStream.send(session.stream, HeadersMessage.getheaders_command(), payload),
         {:ok, stream, %{payload: response_payload}} <-
           MessageStream.read_until_command(stream, HeadersMessage.command(), 120_000) do
      headers = HeadersMessage.deserialize(response_payload)
      {:ok, %{session | stream: stream}, headers}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :header_request_failed}
    end
  end

  def request_block(%__MODULE__{} = session, block_hash_internal)
      when is_binary(block_hash_internal) do
    Enum.reduce_while(
      [InventoryMessages.msg_witness_block(), InventoryMessages.msg_block()],
      {:error, :notfound},
      fn inv_type, _acc ->
        case request_block_once(session, block_hash_internal, inv_type) do
          {:ok, _session, payload} -> {:halt, {:ok, payload}}
          {:error, reason} -> {:halt, {:error, reason}}
          _ -> {:cont, {:error, :notfound}}
        end
      end
    )
    |> case do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_block_once(%__MODULE__{} = session, block_hash_internal, inv_type) do
    inv = {inv_type, block_hash_internal}

    case MessageStream.send(
           session.stream,
           InventoryMessages.getdata_command(),
           InventoryMessages.serialize_getdata([inv])
         ) do
      {:ok, stream} ->
        read_block_response(
          %{session | stream: stream},
          block_hash_internal,
          System.monotonic_time(:millisecond) + 120_000
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_block_response(%__MODULE__{} = session, block_hash_internal, deadline_ms) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      {:error, :timeout}
    else
      case MessageStream.read_until_commands(
             session.stream,
             [BlockMessage.command(), InventoryMessages.notfound_command()],
             120_000
           ) do
        {:ok, stream, %{command: cmd, payload: payload}} ->
          cond do
            cmd == BlockMessage.command() and received_hash_matches?(payload, block_hash_internal) ->
              {:ok, %{session | stream: stream}, payload}

            cmd == BlockMessage.command() ->
              read_block_response(%{session | stream: stream}, block_hash_internal, deadline_ms)

            cmd == InventoryMessages.notfound_command() ->
              {:error, :notfound}

            true ->
              read_block_response(%{session | stream: stream}, block_hash_internal, deadline_ms)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp received_hash_matches?(payload, block_hash_internal) do
    BlockMessage.block_hash_from_payload(payload) == block_hash_internal
  end

  defp handshake_as_initiator(%__MODULE__{} = session) do
    nonce = :rand.uniform(0xFFFF_FFFF_FFFF_FFFF)
    addr = HandshakeMessages.encode_loopback_address(session.port)

    local_version = %HandshakeMessages.VersionMessage{
      version: session.chain.protocol_version,
      services: HandshakeMessages.node_network() ||| HandshakeMessages.node_witness(),
      timestamp: System.system_time(:second),
      addr_recv: addr,
      addr_from: addr,
      nonce: nonce,
      user_agent: session.chain.user_agent,
      start_height: session.start_height,
      relay: false
    }

    with {:ok, stream} <-
           MessageStream.send(
             session.stream,
             HandshakeMessages.version_command(),
             HandshakeMessages.serialize_version(local_version)
           ),
         {:ok, stream, %{payload: remote_payload}} <-
           MessageStream.read_until_command(stream, HandshakeMessages.version_command(), 30_000),
         remote_version = HandshakeMessages.deserialize_version(remote_payload),
         {:ok, stream} <-
           MessageStream.send(
             stream,
             HandshakeMessages.verack_command(),
             HandshakeMessages.serialize_verack()
           ),
         {:ok, stream, %{command: cmd}} <-
           MessageStream.read_until_command(stream, HandshakeMessages.verack_command(), 30_000),
         true <- cmd == HandshakeMessages.verack_command(),
         {:ok, stream} <-
           MessageStream.send(
             stream,
             HandshakeMessages.sendheaders_command(),
             HandshakeMessages.serialize_sendheaders()
           ) do
      {:ok, %{session | stream: stream, remote_version: remote_version}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :handshake_failed}
    end
  end

  defp record_peer(%__MODULE__{conn: conn, host: host, port: port, remote_version: rv}) do
    Exbitnode.Db.ProjectTracker.record_peer_connected(
      conn,
      host,
      port,
      "outbound",
      rv.services,
      rv.version,
      rv.user_agent,
      rv.start_height
    )
  end
end
