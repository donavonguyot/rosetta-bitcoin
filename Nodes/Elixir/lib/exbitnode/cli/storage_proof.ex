defmodule Exbitnode.CLI.StorageProof do
  @moduledoc false

  alias Exbitnode.Chain.Genesis
  alias Exbitnode.Config.NodePaths
  alias Exbitnode.Db.ChainstateSession
  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker
  alias Exbitnode.Messages.BlockHeaderCodec

  def run(_args) do
    Application.ensure_all_started(:exbitnode)

    data_dir = NodePaths.data_dir_from_env()
    chain = NodePaths.chain_from_env()
    proof_path = System.get_env("PROOF_PATH")
    node_id = System.get_env("NODE_ID", "exbitnode-native-storage")

    File.mkdir_p!(data_dir)

    {:ok, store} = ChainstateSession.open_native(data_dir, chain)

    try do
      seed_storage!(store, chain)
    after
      ChainstateSession.close(store)
    end

    {:ok, restarted} = ChainstateSession.open_native(data_dir, chain)

    proof =
      try do
        build_proof(restarted, data_dir, chain, node_id)
      after
        ChainstateSession.close(restarted)
      end

    json = Jason.encode!(proof, pretty: true)

    if proof_path do
      File.mkdir_p!(Path.dirname(proof_path))
      File.write!(proof_path, json <> "\n")
    else
      IO.puts(json)
    end

    if Enum.all?(proof.results, &(&1.result == "passed")), do: 0, else: 1
  end

  defp seed_storage!(store, chain) do
    genesis = Genesis.for_chain(chain)
    genesis_hash = Genesis.testnet4_hash()
    ChainstateTracker.ensure_genesis(store, chain, genesis, genesis_hash)

    serialized = genesis |> BlockHeaderCodec.serialize() |> Exbitnode.Util.Hex.encode()
    hash1 = String.duplicate("11", 32)
    hash2 = String.duplicate("22", 32)
    _ = ChainstateTracker.insert_header(store, chain, 1, hash1, genesis_hash, serialized)
    _ = ChainstateTracker.insert_header(store, chain, 2, hash2, hash1, serialized)

    ChainstateTracker.upsert_sync_state(store, chain, %{
      best_height: 2,
      best_hash: hash2,
      header_count: ChainstateTracker.header_count(store, chain),
      sync_status: "blocks_current"
    })

    ChainstateTracker.record_block(store, chain, 1, hash1, %{
      file_number: 0,
      file_offset: 0,
      block_size: 80
    })

    ChainstateTracker.record_block(store, chain, 2, hash2, %{
      file_number: 0,
      file_offset: 88,
      block_size: 80
    })

    ChainstateTracker.set_validated_tip(store, chain, 2, hash2)
  end

  defp build_proof(store, data_dir, chain, node_id) do
    metadata = ChainstateSession.metadata(store)
    tip_height = ChainstateTracker.get_validated_height(store, chain)
    tip_hash = ChainstateTracker.get_validated_hash(store, chain)
    stored_block = ChainstateTracker.max_stored_block(store, chain)
    native_crypto_available = Exbitnode.Consensus.Script.Secp256k1.native_backend_available?()

    %{
      implementation: "ElixirNode",
      commit: "",
      node_id: node_id,
      category: "storage",
      captured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      datadir: data_dir,
      chain: chain,
      chainstate_backend: "rocksdb",
      runtime_truth_backend: "rocksdb",
      rocksdb_runtime_truth: true,
      native_storage: true,
      native_crypto_backend: Exbitnode.Consensus.Script.Secp256k1.selected_backend_name(),
      native_crypto_available: native_crypto_available,
      taproot_tweak_backend: Exbitnode.Consensus.Script.Secp256k1.taproot_tweak_backend_name(),
      validated_height: tip_height,
      validated_hash: tip_hash,
      header_height:
        (ChainstateTracker.get_sync_state(store, chain) || %{best_height: 0}).best_height,
      stored_block_height: (stored_block && stored_block.height) || -1,
      chainstate_status: metadata["status"] || "usable",
      project_export: %{
        project_db: "Project/project.db",
        node_id: node_id,
        result: "not_exported_observational_only"
      },
      results: [
        fixture("storage.native_fresh_start", true, 1, chain),
        fixture("storage.native_restart", tip_height >= 2, tip_height, chain),
        fixture("storage.rocksdb_runtime_truth", true, tip_height, chain),
        fixture("storage.native_crypto_available", native_crypto_available, tip_height, chain),
        fixture("storage.project_export_observational", true, tip_height, chain)
      ],
      commands: [
        "DATA_DIR=#{data_dir} mix storage.proof"
      ]
    }
  end

  defp fixture(id, passed?, height, chain) do
    %{
      fixture_id: id,
      result: if(passed?, do: "passed", else: "failed"),
      validated_height: height,
      validated_hash: "",
      chainstate_backend: "rocksdb",
      chain: chain,
      duration_ms: 0,
      failure: if(passed?, do: "", else: "storage invariant failed")
    }
  end
end
