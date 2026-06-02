defmodule Exbitnode.Sync.BlockSync do
  @moduledoc false

  alias Exbitnode.Consensus.Connect.{BlockConnector, ConnectBlockError, ValidationBlocker}
  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker
  alias Exbitnode.P2p.{PeerServer, PeerSupervisor}
  alias Exbitnode.Storage.BlockStorage
  alias Exbitnode.Util.Hex

  @default_max_blocks 128
  @default_max_reconnects 5
  @transport_errors [:closed, :timeout, :econnreset, :enotconn, :epipe]

  def default_max_blocks, do: @default_max_blocks

  def sync_from_peer(peer_pid, chain, conn, block_store, max_blocks, peer_ctx \\ nil)
      when is_pid(peer_pid) do
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
      0
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
         reconnects
       ) do
    if max_blocks > 0 and connected >= max_blocks do
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

          case request_block(peer_pid, block_hash_internal, peer_ctx, reconnects) do
            {:ok, payload, peer_pid, reconnects} ->
              downloaded = downloaded + 1
              stored = BlockStorage.store(block_store, payload)

              :ok =
                ChainstateTracker.record_block(
                  conn,
                  chain.name,
                  next_height,
                  header_hash_hex,
                  stored
                )

              try do
                BlockConnector.connect(
                  conn,
                  chain.name,
                  next_height,
                  payload,
                  expected_prev_internal,
                  block_hash_internal
                )

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
                  reconnects
                )
              rescue
                e in ValidationBlocker ->
                  :ok = ChainstateTracker.record_blocker(conn, chain.name, e)
                  ChainstateTracker.log_event(conn, "consensus", e.message, "error")
                  finish(conn, chain.name, downloaded, connected, e, "blocked")

                e in ConnectBlockError ->
                  ChainstateTracker.log_event(conn, "consensus", e.message, "error")
                  finish(conn, chain.name, downloaded, connected, blocker, "failed")

                e ->
                  ChainstateTracker.log_event(conn, "consensus", Exception.message(e), "error")
                  finish(conn, chain.name, downloaded, connected, blocker, "failed")
              end

            {:error, :notfound, peer_pid, reconnects} ->
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
  end

  defp prev_internal(conn, chain, next_height) do
    if next_height == 0 do
      :binary.copy(<<0>>, 32)
    else
      prev_hash_hex = ChainstateTracker.get_header_hash(conn, chain, next_height - 1)
      Hex.reverse(Hex.decode(prev_hash_hex))
    end
  end
end
