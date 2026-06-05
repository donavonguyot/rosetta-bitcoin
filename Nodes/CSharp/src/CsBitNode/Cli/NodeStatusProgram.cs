using System.Text.Json;
using System.Text.Json.Nodes;
using CsBitNode.Chain;
using CsBitNode.Config;
using CsBitNode.Consensus.Script;
using CsBitNode.Db;
using CsBitNode.Storage;

namespace CsBitNode.Cli;

public static class NodeStatusService
{
    public static JsonObject BuildStatus(string chain, string dataDir)
    {
        dataDir = Path.GetFullPath(dataDir);
        var lockInfo = DatadirLock.Inspect(dataDir);
        var chainParams = ChainRegistry.Get(chain);
        using var session = ChainstateSession.OpenNative(dataDir, chainParams, acquireLock: false);
        var store = session.Store;
        var syncState = store.GetSyncState(chain);
        var syncTiming = store.GetSyncTimingSummary(chain);
        var validatedHeight = store.GetValidatedHeight(chain);
        var storedBlockHeight = store.MaxStoredBlockHeight(chain);
        var hasSqliteArtifact = File.Exists(Path.Combine(dataDir, NodePaths.DbFileName));
        var blockerJson = store.CurrentBlockerJson(chain);
        JsonNode? currentBlocker = null;
        if (!string.IsNullOrWhiteSpace(blockerJson))
            currentBlocker = JsonNode.Parse(blockerJson);

        return new JsonObject
        {
            ["chain"] = chain,
            ["datadir"] = dataDir,
            ["utxo_accounting_policy"] = "core_spendable_v1",
            ["native_storage"] = true,
            ["sqlite_free"] = !hasSqliteArtifact,
            ["local_sqlite_artifact_absent"] = !hasSqliteArtifact,
            ["local_sqlite_db_present"] = hasSqliteArtifact,
            ["runtime_status"] = lockInfo.Busy ? "syncing" : "idle",
            ["sync_status"] = syncState?.SyncStatus ?? "not_started",
            ["header_height"] = syncState?.BestHeight ?? 0,
            ["validated_height"] = Math.Max(0, validatedHeight),
            ["validated_hash"] = store.GetValidatedHash(chain) ?? "",
            ["header_count"] = store.HeaderCount(chain),
            ["block_count"] = store.BlockCount(chain),
            ["stored_block_height"] = storedBlockHeight,
            ["stored_minus_validated"] = storedBlockHeight - validatedHeight,
            ["utxo_count"] = store.UtxoCount(chain),
            ["chainstate_backend"] = store.Metadata.BackendName,
            ["chainstate_backend_path"] = store.Metadata.BackendPath,
            ["codec_version"] = RocksDbChainstateStore.CodecVersion,
            ["chainstate_generation_id"] = store.Metadata.GenerationId,
            ["chainstate_status"] = store.Metadata.Status,
            ["native_crypto_backend"] = Secp256k1.SelectedBackendName(),
            ["native_crypto_available"] = Secp256k1.NativeBackendAvailable(),
            ["taproot_tweak_backend"] = Secp256k1.TaprootTweakBackendName(),
            ["sync_timing"] = syncTiming is null ? null : JsonSerializer.SerializeToNode(syncTiming),
            ["current_blocker"] = currentBlocker,
            ["active_writer_pid"] = lockInfo.Pid,
            ["active_writer_command"] = lockInfo.Command,
            ["peer_source"] = Environment.GetEnvironmentVariable("PEERS") ?? "127.0.0.1:48333",
            ["recommendation"] = validatedHeight >= 0 ? "checkpoint" : "run_sync_local",
            ["binary_gate_status"] = "not_attempted"
        };
    }

    public static int Run(string[] args, TextWriter output)
    {
        var chain = NodePaths.ChainFromEnv();
        var dataDir = NodePaths.DataDirFromEnv(null);

        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--datadir" && i + 1 < args.Length)
                dataDir = Path.GetFullPath(args[++i]);
            else if (args[i] == "--chain" && i + 1 < args.Length)
                chain = args[++i];
            else if (args[i] == "--db")
                throw new InvalidOperationException("--db is retired; CSharpNode status reads native chainstate only");
        }

        var status = BuildStatus(chain, dataDir);
        output.WriteLine(status.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }
}

public static class NodeStatusProgram
{
    public static int Run(string[] args) => NodeStatusService.Run(args, Console.Out);
}
