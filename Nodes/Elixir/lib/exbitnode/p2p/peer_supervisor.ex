defmodule Exbitnode.P2p.PeerSupervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def connect(host, port, chain, conn, start_height) do
    spec = %{
      id: {Exbitnode.P2p.PeerServer, host, port},
      start:
        {Exbitnode.P2p.PeerServer, :start_link,
         [[host: host, port: port, chain: chain, conn: conn, start_height: start_height]]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop(peer_pid) when is_pid(peer_pid) do
    Exbitnode.P2p.PeerServer.close(peer_pid)
    DynamicSupervisor.terminate_child(__MODULE__, peer_pid)
  end
end
