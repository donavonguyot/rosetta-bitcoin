defmodule Exbitnode.CLI.NodeStatus do
  @moduledoc false

  alias Exbitnode.Config.NodePaths
  alias Exbitnode.Db.{Database, ProjectTracker, Sql}
  alias Exbitnode.Storage.DatadirLock

  def run(_args) do
    Application.ensure_all_started(:exbitnode)

    data_dir = NodePaths.data_dir_from_env()
    db_path = NodePaths.db_path_from_env(data_dir)
    chain = NodePaths.chain_from_env()
    peer_source = System.get_env("PEERS", "127.0.0.1:48333")

    status =
      if File.exists?(db_path) do
        build_status(db_path, chain, data_dir, peer_source)
      else
        %{
          runtime_status: "idle",
          sync_status: "not_started",
          datadir: data_dir,
          db_path: db_path,
          peer_source: peer_source,
          recommendation: "run_sync_local",
          binary_gate_status: "not_attempted"
        }
      end

    IO.puts(Jason.encode!(status, pretty: true))
    0
  end

  def build_status(db_path, chain, data_dir, peer_source) do
    {lock_busy, lock_pid, lock_cmd} = DatadirLock.inspect_lock(data_dir)

    {:ok, conn} = Database.open(db_path)

    try do
      sync_state = ProjectTracker.get_sync_state(conn, chain)
      validated_height = ProjectTracker.get_validated_height(conn, chain)
      header_count = ProjectTracker.header_count(conn)
      block_count = ProjectTracker.block_count(conn, chain)
      utxo_count = ProjectTracker.utxo_count(conn, chain)
      latest_blocker = read_latest_blocker(conn, chain)
      latest_error = read_latest_error(conn)

      runtime_status =
        resolve_runtime_status(lock_busy, sync_state && sync_state.sync_status, latest_blocker != nil)

      base = %{
        chain: chain,
        datadir: data_dir,
        db_path: db_path,
        runtime_status: runtime_status,
        sync_status: sync_state && sync_state.sync_status || "starting",
        header_height: sync_state && sync_state.best_height || 0,
        validated_height: validated_height,
        header_count: header_count,
        block_count: block_count,
        utxo_count: utxo_count,
        peer_source: peer_source,
        recommendation: recommend(runtime_status, validated_height, block_count, latest_blocker != nil),
        binary_gate_status: binary_gate_status(validated_height, sync_state && sync_state.best_height || 0)
      }

      base
      |> maybe_put(:active_writer_pid, lock_busy && lock_pid)
      |> maybe_put(:active_writer_command, lock_busy && lock_cmd)
      |> maybe_put(:current_blocker, latest_blocker)
      |> maybe_put(:last_error, latest_error)
    after
      Database.close(conn)
    end
  end

  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp resolve_runtime_status(_lock_busy, _sync_status, true), do: "blocked"
  defp resolve_runtime_status(true, _sync_status, _has_blocker), do: "syncing"
  defp resolve_runtime_status(_lock_busy, "failed", _has_blocker), do: "failed"
  defp resolve_runtime_status(_lock_busy, "blocked", _has_blocker), do: "blocked"
  defp resolve_runtime_status(_lock_busy, status, _has_blocker) when status in [nil, "starting", "not_started"], do: "idle"
  defp resolve_runtime_status(_lock_busy, _sync_status, _has_blocker), do: "idle"

  defp recommend("syncing", _, _, _), do: "leave_running"
  defp recommend("blocked", _, _, _), do: "investigate"
  defp recommend("failed", _, _, _), do: "investigate"
  defp recommend(_, validated_height, block_count, false) when validated_height >= 0 and block_count > 0, do: "checkpoint"
  defp recommend(_, validated_height, _, _) when validated_height < 0, do: "run_sync_local"
  defp recommend(_, _, _, _), do: "run_sync_local"

  defp read_latest_blocker(conn, chain) do
    case Sql.query_one(
           conn,
           """
           SELECT height, block_hash, txid, input_index, spent_script_pubkey_hex, failure, missing_rule, created_at
           FROM blockers WHERE chain = ?1 ORDER BY id DESC LIMIT 1
           """,
           [chain]
         ) do
      [height, block_hash, txid, input_index, script_hex, failure, missing_rule, created_at] ->
        %{
          height: height,
          block_hash: block_hash,
          txid: txid,
          input_index: input_index,
          spent_script_pubkey_hex: script_hex,
          failure: failure,
          missing_rule: missing_rule,
          created_at: created_at
        }

      _ ->
        nil
    end
  end

  defp read_latest_error(conn) do
    case Sql.query_one(conn, "SELECT message FROM events WHERE severity = 'error' ORDER BY id DESC LIMIT 1", []) do
      [message] -> message
      _ -> nil
    end
  end

  defp binary_gate_status(validated_height, header_height) do
    cond do
      validated_height < 0 -> "not_attempted"
      validated_height >= header_height -> "passed"
      true -> "failed"
    end
  end
end
