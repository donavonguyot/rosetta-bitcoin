defmodule Exbitnode.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Exbitnode.TaskSupervisor},
      Exbitnode.P2p.PeerSupervisor,
      Exbitnode.Sync.Worker
    ]

    opts = [strategy: :one_for_one, name: Exbitnode.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
