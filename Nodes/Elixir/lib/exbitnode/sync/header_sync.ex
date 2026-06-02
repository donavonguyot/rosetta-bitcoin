defmodule Exbitnode.Sync.HeaderSync do
  @moduledoc false

  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker

  alias Exbitnode.{
    Chain.Genesis,
    Consensus.HeaderValidator,
    Messages.BlockHeaderCodec,
    P2p.PeerServer,
    Util.Hex
  }

  @near_peer_tip 2
  @default_max_headers 2000
  @default_header_batches_max 50

  def default_max_headers, do: @default_max_headers
  def default_header_batches_max, do: @default_header_batches_max

  def sync_from_peer(peer_pid, chain, conn, max_headers, max_batches) when is_pid(peer_pid) do
    genesis = Genesis.for_chain(chain.name)
    genesis_hash = chain.genesis_hash
    ChainstateTracker.ensure_genesis(conn, chain.name, genesis, genesis_hash)
    ChainstateTracker.repair_sync_state_from_headers(conn, chain.name)
    genesis_hash_internal = BlockHeaderCodec.block_hash(genesis)

    peer_height = PeerServer.remote_start_height(peer_pid)
    total_stored = 0

    sync_loop(
      peer_pid,
      chain,
      conn,
      max_headers,
      max_batches,
      peer_height,
      total_stored,
      0,
      genesis_hash_internal
    )
  end

  defp sync_loop(
         peer_pid,
         chain,
         conn,
         max_headers,
         max_batches,
         peer_height,
         total_stored,
         batches,
         genesis_hash_internal
       ) do
    state = ChainstateTracker.get_sync_state(conn, chain.name)
    best_height = (state && state.best_height) || 0

    if should_skip?(peer_height, best_height) do
      mark_headers_current(conn, chain.name)
      result(total_stored, best_height, "headers_current")
    else
      locator =
        ChainstateTracker.next_locator(conn, chain.name, best_height, genesis_hash_internal)

      remaining = max_headers - total_stored

      if remaining <= 0 or batches >= max_batches do
        result(total_stored, best_height, (state && state.sync_status) || "headers_syncing")
      else
        case PeerServer.request_headers(peer_pid, locator) do
          {:ok, headers} ->
            headers = Enum.take(headers, remaining)

            if headers == [] do
              mark_headers_current(conn, chain.name)
              result(total_stored, best_height, "headers_current")
            else
              {stored, tip_height, _tip_internal} =
                persist_headers(conn, chain.name, headers, best_height, genesis_hash_internal)

              total_stored = total_stored + stored
              batches = batches + 1
              state = ChainstateTracker.get_sync_state(conn, chain.name)
              best_height = (state && state.best_height) || tip_height

              cond do
                stored == 0 ->
                  mark_headers_current(conn, chain.name)
                  result(total_stored, best_height, "headers_current")

                headers_sync_done?(best_height, peer_height, length(headers)) ->
                  mark_headers_current(conn, chain.name)
                  result(total_stored, best_height, "headers_current")

                total_stored >= max_headers ->
                  ChainstateTracker.upsert_sync_state(conn, chain.name, %{
                    header_count: ChainstateTracker.header_count(conn, chain.name),
                    sync_status: "headers_syncing"
                  })

                  result(total_stored, best_height, "headers_syncing")

                true ->
                  sync_loop(
                    peer_pid,
                    chain,
                    conn,
                    max_headers,
                    max_batches,
                    peer_height,
                    total_stored,
                    batches,
                    genesis_hash_internal
                  )
              end
            end

          {:error, reason} ->
            ChainstateTracker.log_event(
              conn,
              "sync",
              "header request failed: #{inspect(reason)}",
              "error"
            )

            result(total_stored, best_height, "failed")
        end
      end
    end
  end

  defp should_skip?(peer_height, local_height) do
    peer_height >= 0 and local_height >= peer_height - @near_peer_tip
  end

  defp headers_sync_done?(best_height, peer_height, batch_count) do
    batch_count == 0 or (peer_height >= 0 and best_height >= peer_height)
  end

  defp persist_headers(conn, chain, headers, tip_height, genesis_hash_internal) do
    state = ChainstateTracker.get_sync_state(conn, chain)
    tip_height = (state && state.best_height) || tip_height

    tip_hash_hex =
      ChainstateTracker.get_header_hash(conn, chain, tip_height) || Genesis.testnet4_hash()

    tip_internal =
      if tip_height == 0 do
        genesis_hash_internal
      else
        Hex.reverse(Hex.decode(tip_hash_hex))
      end

    Enum.reduce(headers, {0, tip_height, tip_internal}, fn header,
                                                           {stored, height, prev_internal} ->
      try do
        :ok = HeaderValidator.validate_header(header, prev_internal)
        height = height + 1
        block_hash = BlockHeaderCodec.block_hash_hex(header)
        prev_hash = Hex.encode(Hex.reverse(header.prev_block))
        serialized = header |> BlockHeaderCodec.serialize() |> Hex.encode()

        inserted? =
          case ChainstateTracker.insert_header(
                 conn,
                 chain,
                 height,
                 block_hash,
                 prev_hash,
                 serialized
               ) do
            :inserted -> true
            :exists -> false
          end

        if inserted? do
          :ok =
            ChainstateTracker.upsert_sync_state(conn, chain, %{
              best_height: height,
              best_hash: block_hash,
              header_count: ChainstateTracker.header_count(conn, chain),
              sync_status: "headers_syncing"
            })

          tip_internal = BlockHeaderCodec.block_hash(header)
          {stored + 1, height, tip_internal}
        else
          existing_hash = ChainstateTracker.get_header_hash(conn, chain, height)

          if existing_hash != block_hash do
            raise Exbitnode.Consensus.HeaderValidationError,
                  "header hash mismatch at height #{height}"
          end

          tip_internal = BlockHeaderCodec.block_hash(header)
          {stored, height, tip_internal}
        end
      rescue
        e in Exbitnode.Consensus.HeaderValidationError ->
          ChainstateTracker.log_event(
            conn,
            "sync",
            "Header rejected at height #{height + 1}: #{Exception.message(e)}",
            "warning"
          )

          {stored, height, prev_internal}
      end
    end)
  end

  defp mark_headers_current(conn, chain) do
    state = ChainstateTracker.get_sync_state(conn, chain)

    ChainstateTracker.upsert_sync_state(conn, chain, %{
      best_height: state && state.best_height,
      best_hash: state && state.best_hash,
      header_count: ChainstateTracker.header_count(conn, chain),
      sync_status: "headers_current"
    })
  end

  defp result(stored_total, best_height, sync_status) do
    %{stored_total: stored_total, best_height: best_height, sync_status: sync_status}
  end
end
