defmodule Exbitnode.P2p.PeerServer do
  @moduledoc false

  use GenServer

  alias Exbitnode.P2p.PeerSession

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def remote_start_height(pid) do
    GenServer.call(pid, :remote_start_height)
  end

  def request_headers(pid, locator) do
    GenServer.call(pid, {:request_headers, locator})
  end

  def request_block(pid, block_hash_internal) do
    GenServer.call(pid, {:request_block, block_hash_internal}, 130_000)
  end

  def close(pid) do
    GenServer.cast(pid, :close)
  end

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    chain = Keyword.fetch!(opts, :chain)
    conn = Keyword.fetch!(opts, :conn)
    start_height = Keyword.fetch!(opts, :start_height)

    case PeerSession.connect(host, port, chain, conn, start_height) do
      {:ok, session} -> {:ok, %{session: session}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:remote_start_height, _from, %{session: session} = state) do
    height =
      case session.remote_version do
        %{start_height: h} when is_integer(h) -> h
        _ -> -1
      end

    {:reply, height, state}
  end

  def handle_call({:request_headers, locator}, _from, %{session: session} = state) do
    case PeerSession.request_headers(session, locator) do
      {:ok, session, headers} -> {:reply, {:ok, headers}, %{state | session: session}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request_block, block_hash_internal}, _from, %{session: session} = state) do
    reply =
      case PeerSession.request_block(session, block_hash_internal) do
        {:ok, payload} -> {:ok, payload}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:close, %{session: session} = state) do
    PeerSession.close(session)
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, %{session: session}) do
    PeerSession.close(session)
    :ok
  end
end
