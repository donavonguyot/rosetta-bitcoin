defmodule Exbitnode.CLI.SyncLocal do
  @moduledoc false

  alias Exbitnode.Chain.ChainRegistry
  alias Exbitnode.Config.NodePaths
  alias Exbitnode.Db.ChainstateSession
  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker
  alias Exbitnode.P2p.PeerSupervisor
  alias Exbitnode.Storage.BlockStore
  alias Exbitnode.Storage.DatadirLock
  alias Exbitnode.Sync.{BlockSync, HeaderSync}

  def run(_args) do
    Application.ensure_all_started(:exbitnode)

    chain_name = NodePaths.chain_from_env()
    chain = ChainRegistry.get(chain_name)
    {host, port} = NodePaths.parse_peers(System.get_env("PEERS"), chain.default_port) |> hd()

    max_headers =
      NodePaths.parse_int(System.get_env("HEADERS_MAX"), HeaderSync.default_max_headers())

    max_batches =
      NodePaths.parse_int(
        System.get_env("HEADER_BATCHES_MAX"),
        HeaderSync.default_header_batches_max()
      )

    max_blocks = NodePaths.parse_int(System.get_env("BLOCKS_MAX"), BlockSync.default_max_blocks())
    skip_blocks = NodePaths.parse_bool(System.get_env("SKIP_BLOCKS"), false)

    data_dir = NodePaths.data_dir_from_env()
    blocks_dir = Path.join(data_dir, "blocks")

    IO.puts("exbitnode sync-local")
    IO.puts("  chain=#{chain.name}")
    IO.puts("  chainstate_backend=rocksdb")
    IO.puts("  chainstate_path=#{Path.join(data_dir, "chainstate-rocksdb")}")
    IO.puts("  peer=#{host}:#{port}")
    IO.puts("  headers_max=#{max_headers} batches_max=#{max_batches}")
    IO.puts("  blocks_max=#{max_blocks} skip_blocks=#{skip_blocks}")

    try do
      {:ok, lock} = DatadirLock.acquire(data_dir)
      {:ok, conn} = ChainstateSession.open_native(data_dir, chain.name)
      block_store = BlockStore.new(blocks_dir, chain.magic)

      try do
        ChainstateTracker.repair_sync_state_from_headers(conn, chain.name)
        start_height = ChainstateTracker.bootstrap_start_height(conn, chain.name)

        case PeerSupervisor.connect(host, port, chain, conn, start_height) do
          {:ok, peer} ->
            try do
              header_result =
                HeaderSync.sync_from_peer(peer, chain, conn, max_headers, max_batches)

              IO.puts("  stored_headers=#{header_result.stored_total}")
              IO.puts("  header_height=#{header_result.best_height}")
              IO.puts("  sync_status=#{header_result.sync_status}")

              block_result =
                if skip_blocks do
                  %{
                    downloaded: 0,
                    connected: 0,
                    sync_status: header_result.sync_status,
                    blocker_message: nil
                  }
                else
                  peer_ctx = %{host: host, port: port, chain: chain, conn: conn}
                  BlockSync.sync_from_peer(peer, chain, conn, block_store, max_blocks, peer_ctx)
                end

              unless skip_blocks do
                IO.puts("  downloaded_blocks=#{block_result.downloaded}")
                IO.puts("  connected_blocks=#{block_result.connected}")
                IO.puts("  sync_status=#{block_result.sync_status}")

                if block_result.blocker_message do
                  IO.puts("  current_blocker=#{block_result.blocker_message}")
                end
              end

              validated_height = ChainstateTracker.get_validated_height(conn, chain.name)

              IO.puts("  validated_height=#{validated_height}")
              IO.puts("  utxo_count=#{ChainstateTracker.utxo_count(conn, chain.name)}")

              IO.puts(
                "  binary_gate_status=#{binary_gate_status(validated_height, header_result.best_height)}"
              )

              0
            after
              PeerSupervisor.stop(peer)
            end

          {:error, reason} ->
            IO.puts("  sync_status=error")
            IO.puts("  error=#{inspect(reason)}")
            IO.puts("  binary_gate_status=not_attempted")
            1
        end
      after
        BlockStore.close(block_store)
        ChainstateSession.close(conn)
        DatadirLock.release(lock)
      end
    rescue
      e in DatadirLock.BusyError ->
        IO.puts("  sync_status=error")
        IO.puts("  error=#{Exception.message(e)}")
        IO.puts("  binary_gate_status=not_attempted")
        2
    catch
      kind, reason ->
        IO.puts("  sync_status=error")
        IO.puts("  error=#{inspect({kind, reason})}")
        IO.puts("  binary_gate_status=not_attempted")
        1
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
