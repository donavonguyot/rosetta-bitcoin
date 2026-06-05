defmodule Exbitnode.RuntimeStatus do
  @moduledoc false

  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker

  @snapshot_relative_path Path.join("status", "runtime_status.json")

  def snapshot_path(data_dir), do: Path.join(data_dir, @snapshot_relative_path)

  def read_snapshot(data_dir) do
    path = snapshot_path(data_dir)

    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def write_snapshot(data_dir, fields) when is_map(fields) do
    path = snapshot_path(data_dir)
    File.mkdir_p!(Path.dirname(path))

    snapshot =
      fields
      |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())
      |> stringify_keys()

    tmp = "#{path}.tmp.#{System.unique_integer([:positive])}"
    File.write!(tmp, Jason.encode!(snapshot, pretty: true) <> "\n")
    File.rename!(tmp, path)
    :ok
  end

  def write_store_snapshot(store, data_dir, chain, fields \\ %{}) do
    sync_state = ChainstateTracker.get_sync_state(store, chain)
    stored_block = ChainstateTracker.max_stored_block(store, chain)

    write_snapshot(
      data_dir,
      %{
        runtime_surface: runtime_surface(),
        peer_source: Map.get(fields, :peer_source, ""),
        chain: chain,
        network: chain,
        datadir: data_dir,
        validated_height: ChainstateTracker.get_validated_height(store, chain),
        validated_hash: ChainstateTracker.get_validated_hash(store, chain),
        header_height: (sync_state && sync_state.best_height) || 0,
        header_hash: (sync_state && sync_state.best_hash) || "",
        stored_block_height: (stored_block && stored_block.height) || -1,
        stored_block_hash: (stored_block && stored_block.block_hash) || "",
        block_count: ChainstateTracker.block_count(store, chain),
        utxo_count: ChainstateTracker.utxo_count(store, chain),
        block_prefetch_depth: env_int("BLOCK_PREFETCH_DEPTH", 0),
        snapshot_throttle_blocks: env_int("SYNC_SNAPSHOT_BLOCKS", 0),
        snapshot_throttle_sec: env_int("SYNC_SNAPSHOT_SEC", 5),
        script_verify_timeout_ms: env_int("SCRIPT_VERIFY_TIMEOUT_MS", 300_000),
        sync_status:
          Map.get(fields, :sync_status, (sync_state && sync_state.sync_status) || "starting"),
        current_blocker:
          Map.get(fields, :current_blocker, ChainstateTracker.latest_blocker(store, chain)),
        last_error: Map.get(fields, :last_error, ChainstateTracker.latest_error(store))
      }
      |> Map.merge(Map.get(fields, :extra, %{}))
    )
  end

  def empty_running_snapshot(data_dir, chain, peer_source) do
    %{
      "runtime_surface" => runtime_surface(),
      "peer_source" => peer_source,
      "chain" => chain,
      "network" => chain,
      "datadir" => data_dir,
      "validated_height" => -1,
      "validated_hash" => "",
      "header_height" => -1,
      "header_hash" => "",
      "stored_block_height" => -1,
      "stored_block_hash" => "",
      "block_count" => 0,
      "utxo_count" => 0,
      "block_prefetch_depth" => env_int("BLOCK_PREFETCH_DEPTH", 0),
      "snapshot_throttle_blocks" => env_int("SYNC_SNAPSHOT_BLOCKS", 0),
      "snapshot_throttle_sec" => env_int("SYNC_SNAPSHOT_SEC", 5),
      "script_verify_timeout_ms" => env_int("SCRIPT_VERIFY_TIMEOUT_MS", 300_000),
      "sync_status" => "running",
      "current_blocker" => nil,
      "last_error" => nil,
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  def required_tick_fields(snapshot, phase, process_running, last_height \\ nil) do
    validated_height = Map.get(snapshot, "validated_height", -1)

    delta =
      if is_integer(validated_height) and is_integer(last_height) do
        validated_height - last_height
      else
        0
      end

    %{
      phase: phase,
      runtime_surface: Map.get(snapshot, "runtime_surface", runtime_surface()),
      peer_mode: "local_reference",
      peer: Map.get(snapshot, "peer_source", ""),
      validated_height: validated_height,
      header_height: Map.get(snapshot, "header_height", -1),
      stored_block_height: Map.get(snapshot, "stored_block_height", -1),
      sync_status: Map.get(snapshot, "sync_status", "unknown"),
      delta_since_last: delta,
      process_running: process_running,
      current_blocker: Map.get(snapshot, "current_blocker")
    }
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_value(value)}
      {key, value} -> {key, normalize_value(value)}
    end)
  end

  defp normalize_value(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> stringify_keys()
  end

  defp normalize_value(%{} = map), do: stringify_keys(map)
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(nil), do: nil
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value

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
