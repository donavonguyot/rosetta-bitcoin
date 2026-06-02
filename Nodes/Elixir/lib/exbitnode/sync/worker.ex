defmodule Exbitnode.Sync.Worker do
  @moduledoc false

  use GenServer

  @sync_timeout_ms 3_600_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def run_sync_local(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @sync_timeout_ms)
    GenServer.call(__MODULE__, {:run_sync_local, opts}, timeout + 5_000)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:run_sync_local, opts}, _from, state) do
    timeout = Keyword.get(opts, :timeout, @sync_timeout_ms)

    result =
      Task.Supervisor.async(Exbitnode.TaskSupervisor, fn ->
        Exbitnode.CLI.SyncLocal.run([])
      end)
      |> Task.await(timeout)

    {:reply, {:ok, result}, state}
  end
end
