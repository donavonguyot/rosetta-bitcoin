defmodule Exbitnode.CLI.NodeStatus do
  @moduledoc false

  alias Exbitnode.Config.NodePaths
  alias Exbitnode.Db.ChainstateSession
  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker
  alias Exbitnode.RuntimeStatus
  alias Exbitnode.Storage.DatadirLock

  def run(_args) do
    Application.ensure_all_started(:exbitnode)

    data_dir = NodePaths.data_dir_from_env()
    chain = NodePaths.chain_from_env()
    peer_source = System.get_env("PEERS", "127.0.0.1:48333")

    {status, exit_code} = status_result(data_dir, chain, peer_source)

    IO.puts(Jason.encode!(status, pretty: true))
    exit_code
  end

  def status_result(data_dir, chain, peer_source) do
    native_crypto_available = Exbitnode.Consensus.Script.Secp256k1.native_backend_available?()

    cond do
      not native_crypto_available ->
        {base_status(data_dir, chain, peer_source)
         |> Map.merge(%{
           runtime_status: "not_running",
           sync_status: "error",
           chainstate_status: chainstate_status_for_path(data_dir),
           last_error: "native secp256k1 backend unavailable",
           binary_gate_status: "failed",
           recommendation: "build_native_crypto_backend"
         }), 1}

      File.exists?(Path.join(data_dir, "chainstate-rocksdb")) ->
        status = build_status(data_dir, chain, peer_source)
        {status, status_exit_code(status)}

      true ->
        {base_status(data_dir, chain, peer_source), 0}
    end
  end

  def build_status(data_dir, chain, peer_source) do
    {lock_busy, lock_pid, lock_cmd} = DatadirLock.inspect_lock(data_dir)

    if lock_busy do
      snapshot_status(data_dir, chain, peer_source, lock_pid, lock_cmd)
    else
      do_build_status(data_dir, chain, peer_source, lock_busy, lock_pid, lock_cmd)
    end
  rescue
    MatchError ->
      snapshot_status(data_dir, chain, peer_source, nil, nil)
  end

  defp do_build_status(data_dir, chain, peer_source, lock_busy, lock_pid, lock_cmd) do
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

      snapshot =
        case RuntimeStatus.read_snapshot(data_dir) do
          {:ok, value} -> value
          {:error, _reason} -> %{}
        end

      runtime_status =
        resolve_runtime_status(
          lock_busy,
          sync_state && sync_state.sync_status,
          latest_blocker != nil
        )

      %{
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
        utxo_accounting_policy: "core_spendable_v1",
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
        block_prefetch_depth: env_int("BLOCK_PREFETCH_DEPTH", 0),
        snapshot_throttle_blocks: env_int("SYNC_SNAPSHOT_BLOCKS", 0),
        snapshot_throttle_sec: env_int("SYNC_SNAPSHOT_SEC", 5),
        script_verify_timeout_ms: env_int("SCRIPT_VERIFY_TIMEOUT_MS", 300_000),
        rocksdb_disable_wal: metadata["rocksdb_disable_wal"] || "false",
        sync_timing: Map.get(snapshot, "sync_timing", %{}),
        block_gap_count:
          max(((sync_state && sync_state.best_height) || 0) - max(validated_height, 0), 0),
        lock_status: if(lock_busy, do: "held", else: "free"),
        updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        peer_source: peer_source,
        recommendation:
          recommend(runtime_status, validated_height, block_count, latest_blocker != nil),
        current_blocker: latest_blocker,
        last_error: latest_error,
        active_writer_pid: if(lock_busy, do: lock_pid, else: nil),
        active_writer_command: if(lock_busy, do: lock_cmd, else: nil),
        binary_gate_status: binary_gate_status(latest_blocker, latest_error)
      }
    after
      ChainstateSession.close(conn)
    end
  end

  defp snapshot_status(data_dir, chain, peer_source, lock_pid, lock_cmd) do
    snapshot_result = RuntimeStatus.read_snapshot(data_dir)

    snapshot =
      case snapshot_result do
        {:ok, value} -> value
        {:error, _reason} -> RuntimeStatus.empty_running_snapshot(data_dir, chain, peer_source)
      end

    base_status(data_dir, chain, peer_source)
    |> Map.merge(%{
      runtime_status: "running",
      sync_status: Map.get(snapshot, "sync_status", "running"),
      chainstate_status: chainstate_status_for_path(data_dir),
      header_height: Map.get(snapshot, "header_height", 0),
      header_hash: Map.get(snapshot, "header_hash", ""),
      stored_block_height: Map.get(snapshot, "stored_block_height", -1),
      stored_block_hash: Map.get(snapshot, "stored_block_hash", ""),
      validated_height: Map.get(snapshot, "validated_height", -1),
      validated_hash: Map.get(snapshot, "validated_hash", ""),
      block_count: Map.get(snapshot, "block_count", 0),
      utxo_count: Map.get(snapshot, "utxo_count", 0),
      chainstate_utxo_count: Map.get(snapshot, "utxo_count", 0),
      block_prefetch_depth:
        Map.get(snapshot, "block_prefetch_depth", env_int("BLOCK_PREFETCH_DEPTH", 0)),
      snapshot_throttle_blocks:
        Map.get(snapshot, "snapshot_throttle_blocks", env_int("SYNC_SNAPSHOT_BLOCKS", 0)),
      snapshot_throttle_sec:
        Map.get(snapshot, "snapshot_throttle_sec", env_int("SYNC_SNAPSHOT_SEC", 5)),
      script_verify_timeout_ms:
        Map.get(
          snapshot,
          "script_verify_timeout_ms",
          env_int("SCRIPT_VERIFY_TIMEOUT_MS", 300_000)
        ),
      sync_timing: Map.get(snapshot, "sync_timing", %{}),
      block_gap_count:
        max(
          Map.get(snapshot, "header_height", 0) -
            max(Map.get(snapshot, "validated_height", -1), 0),
          0
        ),
      lock_status: "held",
      active_writer_pid: lock_pid,
      active_writer_command: lock_cmd,
      peer_source: Map.get(snapshot, "peer_source", peer_source),
      current_blocker: Map.get(snapshot, "current_blocker"),
      last_error: Map.get(snapshot, "last_error"),
      recommendation:
        if(snapshot_result == {:error, :enoent},
          do: "wait_for_status_snapshot",
          else: "leave_running"
        ),
      updated_at: Map.get(snapshot, "updated_at", DateTime.utc_now() |> DateTime.to_iso8601()),
      binary_gate_status:
        binary_gate_status(Map.get(snapshot, "current_blocker"), Map.get(snapshot, "last_error"))
    })
  end

  defp base_status(data_dir, chain, peer_source) do
    {lock_busy, lock_pid, lock_cmd} = DatadirLock.inspect_lock(data_dir)

    %{
      node_id: "exbitnode-native",
      implementation: "ElixirNode",
      runtime_surface: runtime_surface(),
      runtime_status: if(lock_busy, do: "running", else: "not_running"),
      sync_status: "not_started",
      chain: chain,
      network: chain,
      datadir: data_dir,
      chainstate_backend: "rocksdb",
      chainstate_backend_path: Path.join(data_dir, "chainstate-rocksdb"),
      chainstate_generation_id: "",
      chainstate_status: chainstate_status_for_path(data_dir),
      header_height: 0,
      header_hash: "",
      stored_block_height: -1,
      stored_block_hash: "",
      validated_height: -1,
      validated_hash: "",
      header_count: 0,
      block_count: 0,
      utxo_count: 0,
      chainstate_utxo_count: 0,
      block_gap_count: 0,
      lock_status: if(lock_busy, do: "held", else: "free"),
      active_writer_pid: if(lock_busy, do: lock_pid, else: nil),
      active_writer_command: if(lock_busy, do: lock_cmd, else: nil),
      native_crypto_backend: Exbitnode.Consensus.Script.Secp256k1.selected_backend_name(),
      native_crypto_available: Exbitnode.Consensus.Script.Secp256k1.native_backend_available?(),
      taproot_tweak_backend: Exbitnode.Consensus.Script.Secp256k1.taproot_tweak_backend_name(),
      block_prefetch_depth: env_int("BLOCK_PREFETCH_DEPTH", 0),
      snapshot_throttle_blocks: env_int("SYNC_SNAPSHOT_BLOCKS", 0),
      snapshot_throttle_sec: env_int("SYNC_SNAPSHOT_SEC", 5),
      script_verify_timeout_ms: env_int("SCRIPT_VERIFY_TIMEOUT_MS", 300_000),
      current_blocker: nil,
      last_error: nil,
      peer_source: peer_source,
      recommendation: "run_sync_local",
      binary_gate_status: "not_attempted",
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp chainstate_status_for_path(data_dir) do
    if File.exists?(Path.join(data_dir, "chainstate-rocksdb")), do: "usable", else: "missing"
  end

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

  defp binary_gate_status(blocker, _last_error) when not is_nil(blocker), do: "failed"
  defp binary_gate_status(_blocker, last_error) when not is_nil(last_error), do: "failed"
  defp binary_gate_status(_blocker, _last_error), do: "not_attempted"

  defp status_exit_code(%{sync_status: "error"}), do: 1
  defp status_exit_code(%{chainstate_status: "misaligned"}), do: 1
  defp status_exit_code(%{native_crypto_available: false}), do: 1
  defp status_exit_code(%{current_blocker: blocker}) when not is_nil(blocker), do: 1
  defp status_exit_code(%{last_error: last_error}) when not is_nil(last_error), do: 1
  defp status_exit_code(_status), do: 0

  defp runtime_surface do
    System.get_env("RUNTIME_SURFACE", "host")
  end

  defp env_int(name, default) do
    case Integer.parse(System.get_env(name) || "") do
      {value, ""} when value >= 0 -> value
      _ -> default
    end
  end
end
