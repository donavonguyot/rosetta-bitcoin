defmodule Exbitnode.Sync.BlockSync do
  @moduledoc false

  alias Exbitnode.Consensus.Connect.{BlockConnector, ConnectBlockError, ValidationBlocker}
  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker
  alias Exbitnode.P2p.{PeerServer, PeerSupervisor}
  alias Exbitnode.RuntimeStatus
  alias Exbitnode.Sync.BlockPrefetcher
  alias Exbitnode.Storage.BlockStorage
  alias Exbitnode.Util.Hex

  @default_max_blocks 128
  @default_max_reconnects 5
  @transport_errors [:closed, :timeout, :econnreset, :enotconn, :epipe]

  def default_max_blocks, do: @default_max_blocks

  def sync_from_peer(peer_pid, chain, conn, block_store, max_blocks, peer_ctx \\ nil)
      when is_pid(peer_pid) do
    reset_timing()

    do_sync(
      peer_pid,
      chain,
      conn,
      block_store,
      max_blocks,
      0,
      0,
      nil,
      "blocks_syncing",
      peer_ctx,
      0,
      BlockPrefetcher.new(block_prefetch_depth())
    )
  end

  defp do_sync(
         peer_pid,
         chain,
         conn,
         block_store,
         max_blocks,
         downloaded,
         connected,
         blocker,
         sync_status,
         peer_ctx,
         reconnects,
         prefetcher
       ) do
    if max_blocks > 0 and connected >= max_blocks do
      BlockPrefetcher.cancel_all(prefetcher)
      finish(conn, chain.name, downloaded, connected, blocker, sync_status)
    else
      next_height = ChainstateTracker.get_validated_height(conn, chain.name) + 1

      header_hash_hex = ChainstateTracker.get_header_hash(conn, chain.name, next_height)

      cond do
        is_nil(header_hash_hex) ->
          ChainstateTracker.log_event(
            conn,
            "sync",
            "missing header at height #{next_height}",
            "error"
          )

          finish(conn, chain.name, downloaded, connected, blocker, "failed")

        true ->
          expected_prev_internal = prev_internal(conn, chain.name, next_height)
          block_hash_internal = Hex.reverse(Hex.decode(header_hash_hex))
          prefetcher = BlockPrefetcher.ensure(prefetcher, peer_pid, chain.name, conn, next_height)

          {download_wait_us, {prefetcher, request_result}} =
            timed(fn ->
              request_block_with_prefetch(prefetcher, next_height, peer_pid, block_hash_internal, peer_ctx, reconnects)
            end)

          bump_timing(:block_download_wait, download_wait_us)

          case request_result do
            {:ok, payload, peer_pid, reconnects} ->
              downloaded = downloaded + 1
              stored = BlockStorage.store(block_store, payload)

              try do
                connect_result =
                  BlockConnector.connect(
                  conn,
                  chain.name,
                  next_height,
                  payload,
                  expected_prev_internal,
                  block_hash_internal,
                  stored
                )

                merge_connector_timing(connect_result)
                write_progress_snapshot(conn, chain.name, peer_ctx, "blocks_syncing")

                do_sync(
                  peer_pid,
                  chain,
                  conn,
                  block_store,
                  max_blocks,
                  downloaded,
                  connected + 1,
                  blocker,
                  "blocks_syncing",
                  peer_ctx,
                  reconnects,
                  prefetcher
                )
              rescue
                e in ValidationBlocker ->
                  BlockPrefetcher.cancel_all(prefetcher)
                  :ok = ChainstateTracker.record_blocker(conn, chain.name, e)
                  ChainstateTracker.log_event(conn, "consensus", e.message, "error")
                  write_progress_snapshot(conn, chain.name, peer_ctx, "blocked", e, nil)
                  finish(conn, chain.name, downloaded, connected, e, "blocked")

                e in ConnectBlockError ->
                  BlockPrefetcher.cancel_all(prefetcher)
                  ChainstateTracker.log_event(conn, "consensus", e.message, "error")
                  write_progress_snapshot(conn, chain.name, peer_ctx, "failed", nil, e.message)
                  finish(conn, chain.name, downloaded, connected, blocker, "failed")

                e ->
                  BlockPrefetcher.cancel_all(prefetcher)
                  ChainstateTracker.log_event(conn, "consensus", Exception.message(e), "error")
                  write_progress_snapshot(conn, chain.name, peer_ctx, "failed", nil, Exception.message(e))
                  finish(conn, chain.name, downloaded, connected, blocker, "failed")
              end

            {:error, :notfound, peer_pid, reconnects} ->
              BlockPrefetcher.cancel_all(prefetcher)
              ChainstateTracker.log_event(
                conn,
                "sync",
                "peer did not return block at height #{next_height}",
                "warning"
              )

              finish(
                conn,
                chain.name,
                downloaded,
                connected,
                blocker,
                "blocked",
                peer_pid,
                reconnects
              )

            {:error, reason, peer_pid, reconnects} ->
              BlockPrefetcher.cancel_all(prefetcher)
              ChainstateTracker.log_event(
                conn,
                "sync",
                "peer transport error at height #{next_height}: #{inspect(reason)}",
                "error"
              )

              finish(
                conn,
                chain.name,
                downloaded,
                connected,
                blocker,
                "failed",
                peer_pid,
                reconnects
              )
          end
      end
    end
  end

  defp request_block_with_prefetch(prefetcher, next_height, peer_pid, block_hash_internal, peer_ctx, reconnects) do
    case BlockPrefetcher.pop(prefetcher, next_height) do
      {prefetcher, {:ok, payload}} ->
        {prefetcher, {:ok, payload, peer_pid, reconnects}}

      {prefetcher, :miss} ->
        {prefetcher, request_block(peer_pid, block_hash_internal, peer_ctx, reconnects)}

      {prefetcher, _error} ->
        prefetcher = BlockPrefetcher.cancel_all(prefetcher)
        {prefetcher, request_block(peer_pid, block_hash_internal, peer_ctx, reconnects)}
    end
  end

  defp request_block(peer_pid, block_hash_internal, peer_ctx, reconnects) do
    case PeerServer.request_block(peer_pid, block_hash_internal) do
      {:ok, payload} ->
        {:ok, payload, peer_pid, reconnects}

      {:error, :notfound} ->
        {:error, :notfound, peer_pid, reconnects}

      {:error, reason} when reason in @transport_errors ->
        if peer_ctx && reconnects < max_reconnects(peer_ctx) do
          ChainstateTracker.log_event(
            peer_ctx.conn,
            "sync",
            "peer #{inspect(reason)} at block request; reconnecting (#{reconnects + 1}/#{max_reconnects(peer_ctx)})",
            "warning"
          )

          stop_peer(peer_pid)

          case reconnect_peer(peer_ctx) do
            {:ok, new_peer} ->
              request_block(new_peer, block_hash_internal, peer_ctx, reconnects + 1)

            {:error, reason} ->
              {:error, reason, peer_pid, reconnects + 1}
          end
        else
          {:error, reason, peer_pid, reconnects}
        end

      {:error, reason} ->
        {:error, reason, peer_pid, reconnects}
    end
  end

  defp reconnect_peer(%{host: host, port: port, chain: chain, conn: conn}) do
    start_height = ChainstateTracker.bootstrap_start_height(conn, chain.name)
    PeerSupervisor.connect(host, port, chain, conn, start_height)
  end

  defp stop_peer(peer_pid) when is_pid(peer_pid) do
    try do
      PeerSupervisor.stop(peer_pid)
    catch
      :exit, _ -> :ok
    end
  end

  defp max_reconnects(peer_ctx) do
    Map.get(peer_ctx, :max_reconnects, @default_max_reconnects)
  end

  defp block_prefetch_depth do
    case Integer.parse(System.get_env("BLOCK_PREFETCH_DEPTH") || "4") do
      {depth, ""} when depth >= 0 -> depth
      _ -> 4
    end
  end

  defp finish(
         conn,
         chain,
         downloaded,
         connected,
         blocker,
         sync_status,
         _peer_pid \\ nil,
         _reconnects \\ 0
       ) do
    ChainstateTracker.upsert_sync_state(conn, chain, %{sync_status: sync_status})

    %{
      downloaded: downloaded,
      connected: connected,
      sync_status: sync_status,
      blocker_message: blocker && blocker.message
    }
    |> maybe_put_timing()
  end

  defp write_progress_snapshot(conn, chain, peer_ctx, sync_status, blocker \\ nil, last_error \\ nil) do
    data_dir = peer_ctx && Map.get(peer_ctx, :data_dir)
    peer_source = peer_ctx && "#{peer_ctx.host}:#{peer_ctx.port}"

    if data_dir do
      RuntimeStatus.write_store_snapshot(conn, data_dir, chain, %{
        peer_source: peer_source,
        sync_status: sync_status,
        current_blocker: blocker,
        last_error: last_error
      })
    end
  end

  defp prev_internal(conn, chain, next_height) do
    if next_height == 0 do
      :binary.copy(<<0>>, 32)
    else
      prev_hash_hex = ChainstateTracker.get_header_hash(conn, chain, next_height - 1)
      Hex.reverse(Hex.decode(prev_hash_hex))
    end
  end

  defp reset_timing do
    if timing_enabled?() do
      Process.put(:exbitnode_sync_timing, %{
        utxo_load: 0,
        script_verify: 0,
        script_runner_wait: 0,
        utxo_apply: 0,
        commit: 0,
        block_download_wait: 0,
        block_connect_store_commit: 0
      })
    end
  end

  defp merge_connector_timing(%{timing: timing}) when is_map(timing) do
    Enum.each(timing, fn {key, value} -> bump_timing(key, value) end)
  end

  defp merge_connector_timing(_result), do: :ok

  defp bump_timing(key, delta) when is_integer(delta) do
    if timing_enabled?() do
      timing = Process.get(:exbitnode_sync_timing, %{})
      Process.put(:exbitnode_sync_timing, Map.update(timing, key, delta, &(&1 + delta)))
    end

    :ok
  end

  defp maybe_put_timing(result) do
    if timing_enabled?() do
      Map.put(result, :timing, Process.get(:exbitnode_sync_timing, %{}))
    else
      result
    end
  end

  defp timed(fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - start, result}
  end

  defp timing_enabled? do
    (System.get_env("SYNC_TIMING") || "") in ["1", "true", "TRUE", "yes", "YES"]
  end
end
