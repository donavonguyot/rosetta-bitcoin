defmodule Exbitnode.Sync.Runner do
  @moduledoc false

  def run_sync_local(opts \\ []) do
    case Exbitnode.Sync.Worker.run_sync_local(opts) do
      {:ok, exit_code} -> exit_code
      {:error, :sync_already_running} -> raise "sync already running"
      {:error, reason} -> raise "sync worker failed: #{inspect(reason)}"
    end
  end
end
