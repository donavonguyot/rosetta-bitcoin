defmodule Exbitnode.Wire.MessageStream do
  @moduledoc false

  alias Exbitnode.Wire.{MessageFramer, WireSerialize}

  defstruct [:socket, :magic, :buffer]

  def new(socket, magic) do
    %__MODULE__{socket: socket, magic: magic, buffer: <<>>}
  end

  def send(%__MODULE__{} = stream, command, payload) when is_binary(payload) do
    frame = MessageFramer.build_message(stream.magic, command, payload)

    case :gen_tcp.send(stream.socket, frame) do
      :ok -> {:ok, stream}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_message(%__MODULE__{} = stream, timeout \\ 120_000) do
    with {:ok, stream, header_bin} <- read_exact(stream, MessageFramer.header_size(), timeout),
         header = MessageFramer.parse_header(header_bin),
         true <- header.magic == stream.magic,
         {:ok, stream, payload} <- read_exact(stream, header.length, timeout),
         true <- MessageFramer.verify_checksum(payload, header.checksum) do
      {:ok, stream, %{command: header.command, payload: payload}}
    else
      false ->
        {:error, :bad_magic_or_checksum}

      {:error, _} = err ->
        err
    end
  end

  def read_until_command(stream, command, timeout \\ 120_000) do
    read_until_commands(stream, [command], timeout)
  end

  def read_until_commands(stream, commands, timeout \\ 120_000) do
    case read_message(stream, timeout) do
      {:ok, stream, %{command: cmd} = message} ->
        if cmd in commands do
          {:ok, stream, message}
        else
          read_until_commands(stream, commands, timeout)
        end

      {:error, _} = err ->
        err
    end
  end

  defp read_exact(%__MODULE__{buffer: buffer} = stream, count, timeout) do
    stream = %{stream | buffer: buffer}

    case ensure_bytes(stream, count, timeout) do
      {:ok, stream} ->
        <<chunk::binary-size(count), rest::binary>> = stream.buffer
        {:ok, %{stream | buffer: rest}, chunk}

      {:error, _} = err ->
        err
    end
  end

  defp ensure_bytes(%__MODULE__{buffer: buffer} = stream, count, timeout) do
    if byte_size(buffer) >= count do
      {:ok, stream}
    else
      case :gen_tcp.recv(stream.socket, 0, timeout) do
        {:ok, chunk} ->
          ensure_bytes(%{stream | buffer: buffer <> chunk}, count, timeout)

        {:error, :closed} ->
          {:error, :closed}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
