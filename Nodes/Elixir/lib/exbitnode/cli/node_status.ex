defmodule Exbitnode.CLI.NodeStatus do
  @moduledoc false

  alias Exbitnode.Config.NodePaths
  alias Exbitnode.Db.ChainstateSession
  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker
  alias Exbitnode.Storage.DatadirLock

  def run(_args) do
    Application.ensure_all_started(:exbitnode)

    data_dir = NodePaths.data_dir_from_env()
    chain = NodePaths.chain_from_env()
    peer_source = System.get_env("PEERS", "127.0.0.1:48333")

    status =
      if File.exists?(Path.join(data_dir, "chainstate-rocksdb")) do
        build_status(data_dir, chain, peer_source)
      else
        %{
          node_id: "exbitnode-native",
          implementation: "ElixirNode",
          runtime_surface: runtime_surface(),
          runtime_status: "not_running",
          sync_status: "not_started",
          chain: chain,
          network: chain,
          datadir: data_dir,
          chainstate_backend: "rocksdb",
          chainstate_backend_path: Path.join(data_dir, "chainstate-rocksdb"),
          chainstate_generation_id: "",
          chainstate_status: "missing",
          native_crypto_backend: Exbitnode.Consensus.Script.Secp256k1.selected_backend_name(),
          native_crypto_available:
            Exbitnode.Consensus.Script.Secp256k1.native_backend_available?(),
          taproot_tweak_backend:
            Exbitnode.Consensus.Script.Secp256k1.taproot_tweak_backend_name(),
          peer_source: peer_source,
          recommendation: "run_sync_local",
          binary_gate_status: "not_attempted",
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      end

    IO.puts(Jason.encode!(status, pretty: true))
    0
  end

  def build_status(data_dir, chain, peer_source) do
    {lock_busy, lock_pid, lock_cmd} = DatadirLock.inspect_lock(data_dir)

    {:ok, conn} = ChainstateSession.open_native(data_dir, chain)

    try do
      sync_state = ChainstateTracker.get_sync_state(conn, chain)
      validated_height = ChainstateTracker.get_validated_height(conn, chain)
      validated_hash = ChainstateTracker.get_validated_hash(conn, chain)
      header_count = ChainstateTracker.header_count(conn, chain)
      block_count = ChainstateTracker.block_count(conn, chain)
      utxo_count = ChainstateTracker.utxo_count(conn, chain)
      latest_blocker = ChainstateTracker.latest_blocker(conn, chain)
      latest_error = ChainstateTracker.latest_error(conn)
      stored_block = ChainstateTracker.max_stored_block(conn, chain)
      metadata = ChainstateSession.metadata(conn)

      runtime_status =
        resolve_runtime_status(
          lock_busy,
          sync_state && sync_state.sync_status,
          latest_blocker != nil
        )

      base = %{
        node_id: "exbitnode-native",
        implementation: "ElixirNode",
        runtime_surface: runtime_surface(),
        chain: chain,
        network: chain,
        datadir: data_dir,
        runtime_status: runtime_status,
        sync_status: (sync_state && sync_state.sync_status) || "starting",
        header_height: (sync_state && sync_state.best_height) || 0,
        header_hash: (sync_state && sync_state.best_hash) || "",
        stored_block_height: (stored_block && stored_block.height) || -1,
        stored_block_hash: (stored_block && stored_block.block_hash) || "",
        validated_height: validated_height,
        validated_hash: validated_hash,
        header_count: header_count,
        block_count: block_count,
        utxo_count: utxo_count,
        chainstate_backend: "rocksdb",
        chainstate_backend_path: metadata["backend_path"],
        chainstate_generation_id: metadata["generation_id"],
        chainstate_status: metadata["status"] || "usable",
        chainstate_utxo_count: utxo_count,
        native_crypto_backend: Exbitnode.Consensus.Script.Secp256k1.selected_backend_name(),
        native_crypto_available: Exbitnode.Consensus.Script.Secp256k1.native_backend_available?(),
        taproot_tweak_backend: Exbitnode.Consensus.Script.Secp256k1.taproot_tweak_backend_name(),
        block_gap_count:
          max(((sync_state && sync_state.best_height) || 0) - max(validated_height, 0), 0),
        lock_status: if(lock_busy, do: "held", else: "free"),
        updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        peer_source: peer_source,
        recommendation:
          recommend(runtime_status, validated_height, block_count, latest_blocker != nil),
        binary_gate_status:
          binary_gate_status(validated_height, (sync_state && sync_state.best_height) || 0)
      }

      base
      |> maybe_put(:active_writer_pid, lock_busy && lock_pid)
      |> maybe_put(:active_writer_command, lock_busy && lock_cmd)
      |> maybe_put(:current_blocker, latest_blocker)
      |> maybe_put(:last_error, latest_error)
    after
      ChainstateSession.close(conn)
    end
  end

  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp resolve_runtime_status(_lock_busy, _sync_status, true), do: "stopped"
  defp resolve_runtime_status(true, _sync_status, _has_blocker), do: "running"
  defp resolve_runtime_status(_lock_busy, _status, _has_blocker), do: "not_running"

  defp recommend("syncing", _, _, _), do: "leave_running"
  defp recommend("blocked", _, _, _), do: "investigate"
  defp recommend("failed", _, _, _), do: "investigate"

  defp recommend(_, validated_height, block_count, false)
       when validated_height >= 0 and block_count > 0, do: "checkpoint"

  defp recommend(_, validated_height, _, _) when validated_height < 0, do: "run_sync_local"
  defp recommend(_, _, _, _), do: "run_sync_local"

  defp binary_gate_status(validated_height, header_height) do
    cond do
      validated_height < 0 -> "not_attempted"
      validated_height >= header_height -> "passed"
      true -> "failed"
    end
  end

  defp runtime_surface do
    System.get_env("RUNTIME_SURFACE", "host")
  end
end
