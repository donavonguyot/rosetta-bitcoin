package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"sort"
	"strconv"
	"time"

	"rosettabitcoin/nodes/go/internal/connect"
	"rosettabitcoin/nodes/go/internal/crypto"
	p2psync "rosettabitcoin/nodes/go/internal/p2p"
	"rosettabitcoin/nodes/go/internal/refsync"
	"rosettabitcoin/nodes/go/internal/status"
	"rosettabitcoin/nodes/go/internal/storage"
	"rosettabitcoin/nodes/go/internal/surface"
)

func main() {
	datadir := flag.String("datadir", "./data-go-docker-proof", "native datadir")
	target := flag.Int("target", 10000, "target height")
	rpcURL := flag.String("rpc-url", "http://127.0.0.1:48332", "Bitcoin Core RPC URL")
	rpcUser := flag.String("rpc-user", "rosetta", "Bitcoin Core RPC user")
	rpcPassword := flag.String("rpc-password", "rosetta-dev-only", "Bitcoin Core RPC password")
	p2pPeer := flag.String("peer", "127.0.0.1:48333", "Bitcoin Core P2P peer")
	resultPath := flag.String("result-path", "", "proof result path")
	progress := flag.Int("progress", 1000, "progress interval")
	mode := flag.String("mode", "pipeline", "proof mode: pipeline or staged")
	byteSource := flag.String("byte-source", "rpc", "byte source: p2p or rpc")
	flag.Parse()

	started := time.Now().UTC()
	peerMode := "local_reference_rpc"
	peer := *rpcURL
	proofMode := *mode
	byteSourceValue := "local_reference_rpc"
	benchmarkLane := supportingLane(*target, "rpc_replay")
	if *byteSource == "p2p" {
		peerMode = "local_reference"
		peer = *p2pPeer
		proofMode = "p2p_sync"
		byteSourceValue = "local_reference_p2p"
		benchmarkLane = supportingLane(*target, "p2p")
	}
	doc := map[string]any{
		"implementation":             "GoNode",
		"category":                   "local_reference_sync",
		"runtime_surface":            surface.RuntimeSurface(),
		"captured_at":                started.Format(time.RFC3339),
		"chain":                      "testnet4",
		"peer_mode":                  peerMode,
		"peer":                       peer,
		"docker_volume":              firstNonEmpty(os.Getenv("DOCKER_LOCAL_PROOF_VOLUME"), os.Getenv("DOCKER_PROOF_VOLUME")),
		"datadir":                    *datadir,
		"target_height":              *target,
		"header_target_height":       *target,
		"target_label":               targetLabel(*target),
		"reference_start_height":     0,
		"reference_start_hash":       "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043",
		"reference_finish_height":    *target,
		"benchmark_contract_version": 1,
		"benchmark_kind":             benchmarkKind(*target, *byteSource),
		"benchmark_lane":             benchmarkLane,
		"utxo_accounting_policy":     "core_spendable_v1",
		"byte_source":                byteSourceValue,
		"resume_supported":           true,
		"fresh_state":                true,
		"proof_mode":                 proofMode,
		"result":                     "failed",
		"failures":                   []string{},
	}
	profiler := startProfiler(*datadir)

	var syncSummary refsync.Summary
	var connectSummary connect.Summary
	var err error
	if *mode == "staged" {
		if *byteSource == "p2p" {
			fail(doc, "staged mode is only supported for RPC replay")
			profiler.stop(doc)
			finish(doc, *resultPath, 1)
		}
		syncSummary, err = refsync.Run(refsync.Options{
			DataDir:  *datadir,
			Target:   *target,
			RPCURL:   *rpcURL,
			RPCUser:  *rpcUser,
			RPCPass:  *rpcPassword,
			Progress: *progress,
		})
		doc["sync_summary"] = syncSummary
		if err != nil {
			fail(doc, fmt.Sprintf("sync failed: %v", err))
			profiler.stop(doc)
			finish(doc, *resultPath, 1)
		}
		connectSummary, err = connect.Run(connect.Options{
			DataDir:  *datadir,
			Target:   *target,
			Progress: *progress,
		})
	} else {
		if *byteSource == "p2p" {
			syncSummary, connectSummary, err = runP2PPipeline(*datadir, *target, *p2pPeer, *progress)
		} else {
			syncSummary, connectSummary, err = runPipeline(*datadir, *target, *rpcURL, *rpcUser, *rpcPassword, *progress)
		}
		doc["sync_summary"] = syncSummary
		doc["prefetch_depth"] = prefetchDepth()
		doc["timing_summary"] = connectSummary.TimingSummary
	}
	doc["connect_summary"] = connectSummary
	if err != nil {
		fail(doc, fmt.Sprintf("%s proof failed: %v", *mode, err))
		profiler.stop(doc)
		finish(doc, *resultPath, 1)
	}

	statusDoc, err := status.Build(*datadir)
	if err != nil {
		fail(doc, fmt.Sprintf("status failed: %v", err))
	} else {
		doc["status"] = statusDoc
		doc["header_height"] = statusDoc.HeaderHeight
		doc["reference_finish_hash"] = statusDoc.HeaderHash
		doc["validated_height"] = statusDoc.ValidatedHeight
		doc["validated_hash"] = statusDoc.ValidatedHash
		doc["stored_block_height"] = statusDoc.StoredBlockHeight
		doc["sync_status"] = statusDoc.SyncStatus
		doc["current_blocker"] = statusDoc.CurrentBlocker
		doc["chainstate_backend"] = statusDoc.ChainstateBackend
		doc["chainstate_backend_path"] = statusDoc.ChainstateBackendPath
		doc["chainstate_status"] = statusDoc.ChainstateStatus
		doc["chainstate_utxo_count"] = statusDoc.ChainstateUTXOCount
		doc["native_storage"] = statusDoc.ChainstateBackend == "rocksdb"
		doc["binary_gate_status"] = statusDoc.BinaryGateStatus
	}

	info := crypto.Info()
	doc["native_crypto_backend"] = info.ECDSABackend
	doc["native_crypto_available"] = info.NativeAvailable
	doc["taproot_tweak_backend"] = info.TaprootTweakBackend
	doc["storage_codec_version"] = connectSummary.StorageCodec
	doc["rocksdb_tuning"] = connectSummary.RocksDBTuning
	doc["rocksdb_wal_disabled"] = connectSummary.RocksDBWALDisabled
	doc["script_runner_mode"] = connectSummary.ScriptRunnerMode
	doc["script_threads"] = connectSummary.ScriptThreads
	doc["crypto_context_mode"] = connectSummary.CryptoContextMode
	doc["blocks_fetched"] = syncSummary.BlocksFetched
	doc["blocks_connected"] = connectSummary.BlocksConnected
	doc["updated_at"] = time.Now().UTC().Format(time.RFC3339)
	profiler.stop(doc)

	passed := connectSummary.ReachedTarget && connectSummary.ValidatedHeight >= *target && len(failures(doc)) == 0
	if passed {
		doc["result"] = "passed"
		doc["local_reference_status"] = "target_reached"
		finish(doc, *resultPath, 0)
	}
	doc["local_reference_status"] = "blocked_or_incomplete"
	if connectSummary.CurrentBlocker != nil {
		fail(doc, "connect stopped with current_blocker")
	}
	finish(doc, *resultPath, 2)
}

type fetchedBlock struct {
	height int
	hash   string
	raw    []byte
	info   refsync.BlockInfo
	err    error
}

func runPipeline(datadir string, target int, rpcURL, rpcUser, rpcPassword string, progress int) (refsync.Summary, connect.Summary, error) {
	if target < 0 {
		return refsync.Summary{}, connect.Summary{}, fmt.Errorf("target must be >= 0")
	}
	if progress <= 0 {
		progress = 1000
	}
	started := time.Now().UTC()
	client := &refsync.Client{URL: rpcURL, User: rpcUser, Password: rpcPassword}
	store, err := storage.Open(datadir)
	if err != nil {
		return refsync.Summary{}, connect.Summary{}, err
	}
	defer store.Close()
	blocks := make(chan fetchedBlock, prefetchDepth())
	go func() {
		defer close(blocks)
		prev := ""
		for height := 0; height <= target; height++ {
			hash, err := client.BlockHash(height)
			if err != nil {
				blocks <- fetchedBlock{height: height, err: err}
				return
			}
			raw, err := client.RawBlock(hash)
			if err != nil {
				blocks <- fetchedBlock{height: height, err: err}
				return
			}
			info, err := refsync.ValidateBlock(raw, hash, prev)
			if err != nil {
				blocks <- fetchedBlock{height: height, err: err}
				return
			}
			prev = info.Hash
			blocks <- fetchedBlock{height: height, hash: info.Hash, raw: raw, info: info}
		}
	}()
	aggregate := connect.TimingSummary{StageTotalsMillis: map[string]int64{}}
	var lastConnect connect.Summary
	fetched := 0
	for block := range blocks {
		if block.err != nil {
			return syncSummary(target, block.height, "local_reference_rpc", rpcURL, started, fetched, lastConnect), lastConnect, fmt.Errorf("height %d: %w", block.height, block.err)
		}
		storeStart := time.Now()
		if err := store.RecordBlock(block.height, block.hash, block.raw); err != nil {
			return syncSummary(target, block.height, "local_reference_rpc", rpcURL, started, fetched, lastConnect), lastConnect, err
		}
		meta, err := metadataAfterStore(store, block.height, block.hash, started)
		if err != nil {
			return syncSummary(target, block.height, "local_reference_rpc", rpcURL, started, fetched, lastConnect), lastConnect, err
		}
		if err := store.PutMetadata(meta); err != nil {
			return syncSummary(target, block.height, "local_reference_rpc", rpcURL, started, fetched, lastConnect), lastConnect, err
		}
		aggregate.StageTotalsMillis["block_store"] += time.Since(storeStart).Milliseconds()
		connectStart := time.Now()
		lastConnect, err = connect.RunStore(store, connect.Options{Target: block.height, Progress: progress, Quiet: true})
		aggregate.StageTotalsMillis["block_connect_store_commit"] += time.Since(connectStart).Milliseconds()
		if err != nil {
			return syncSummary(target, block.height, "local_reference_rpc", rpcURL, started, fetched, lastConnect), lastConnect, err
		}
		mergeTiming(&aggregate, lastConnect.TimingSummary)
		fetched++
		if block.height%progress == 0 || block.height == target {
			fmt.Printf("gobitnode-local-reference-proof pipeline height=%d hash=%s txs=%d utxos=%d\n", block.height, block.hash, block.info.TxCount, lastConnect.ChainstateUTXOs)
		}
	}
	aggregate.TotalMillis = time.Since(started).Milliseconds()
	lastConnect.Mode = "local_reference_pipeline_connect"
	lastConnect.TargetHeight = target
	lastConnect.BlocksConnected = fetched
	lastConnect.StartedAt = started.Format(time.RFC3339)
	lastConnect.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	lastConnect.TimingSummary = aggregate
	return syncSummary(target, target, "local_reference_rpc", rpcURL, started, fetched, lastConnect), lastConnect, nil
}

func runP2PPipeline(datadir string, target int, peer string, progress int) (refsync.Summary, connect.Summary, error) {
	if target < 0 {
		return refsync.Summary{}, connect.Summary{}, fmt.Errorf("target must be >= 0")
	}
	if progress <= 0 {
		progress = 1000
	}
	started := time.Now().UTC()
	store, err := storage.Open(datadir)
	if err != nil {
		return refsync.Summary{}, connect.Summary{}, err
	}
	defer store.Close()
	blocks := p2psync.FetchBlocks(p2psync.FetchOptions{
		Peer:     peer,
		Target:   target,
		Prefetch: prefetchDepth(),
	})
	aggregate := connect.TimingSummary{StageTotalsMillis: map[string]int64{}}
	var lastConnect connect.Summary
	fetched := 0
	for block := range blocks {
		if block.Err != nil {
			return syncSummary(target, block.Height, "local_reference", peer, started, fetched, lastConnect), lastConnect, fmt.Errorf("height %d: %w", block.Height, block.Err)
		}
		storeStart := time.Now()
		if err := store.RecordBlock(block.Height, block.Hash, block.Raw); err != nil {
			return syncSummary(target, block.Height, "local_reference", peer, started, fetched, lastConnect), lastConnect, err
		}
		meta, err := metadataAfterStore(store, block.Height, block.Hash, started)
		if err != nil {
			return syncSummary(target, block.Height, "local_reference", peer, started, fetched, lastConnect), lastConnect, err
		}
		if err := store.PutMetadata(meta); err != nil {
			return syncSummary(target, block.Height, "local_reference", peer, started, fetched, lastConnect), lastConnect, err
		}
		aggregate.StageTotalsMillis["block_store"] += time.Since(storeStart).Milliseconds()
		connectStart := time.Now()
		lastConnect, err = connect.RunStore(store, connect.Options{Target: block.Height, Progress: progress, Quiet: true})
		aggregate.StageTotalsMillis["block_connect_store_commit"] += time.Since(connectStart).Milliseconds()
		if err != nil {
			return syncSummary(target, block.Height, "local_reference", peer, started, fetched, lastConnect), lastConnect, err
		}
		mergeTiming(&aggregate, lastConnect.TimingSummary)
		fetched++
		if block.Height%progress == 0 || block.Height == target {
			fmt.Printf("gobitnode-local-reference-proof p2p height=%d hash=%s txs=%d utxos=%d\n", block.Height, block.Hash, block.Info.TxCount, lastConnect.ChainstateUTXOs)
		}
	}
	aggregate.TotalMillis = time.Since(started).Milliseconds()
	lastConnect.Mode = "local_reference_p2p_connect"
	lastConnect.TargetHeight = target
	lastConnect.BlocksConnected = fetched
	lastConnect.StartedAt = started.Format(time.RFC3339)
	lastConnect.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	lastConnect.TimingSummary = aggregate
	return syncSummary(target, target, "local_reference", peer, started, fetched, lastConnect), lastConnect, nil
}

func metadataAfterStore(store *storage.Store, height int, hash string, started time.Time) (storage.Metadata, error) {
	meta, err := store.Metadata()
	if err != nil {
		meta = storage.Metadata{
			NodeID:            "gobitnode-local-reference-sync",
			GenerationID:      "go-reference-sync",
			Chain:             "testnet4",
			ChainstateStatus:  "usable",
			ChainstateBackend: "rocksdb",
			ValidatedHeight:   0,
			ValidatedHash:     "",
		}
	}
	meta.NodeID = "gobitnode-local-reference-sync"
	meta.GenerationID = "go-reference-sync"
	meta.Chain = "testnet4"
	meta.ChainstateStatus = "usable"
	meta.ChainstateBackend = "rocksdb"
	meta.HeaderHeight = height
	meta.HeaderHash = hash
	meta.StoredBlockHeight = height
	meta.StoredBlockHash = hash
	meta.CurrentBlocker = nil
	meta.LastError = ""
	if meta.ValidatedHeight >= height {
		meta.SyncStatus = "blocks_current"
	} else {
		meta.SyncStatus = "blocks_syncing"
	}
	if height == 0 && meta.ValidatedHash == "" {
		meta.SyncStatus = "blocks_current"
	}
	_ = started
	return meta, nil
}

func syncSummary(target int, storedHeight int, peerMode string, peer string, started time.Time, fetched int, connectSummary connect.Summary) refsync.Summary {
	return refsync.Summary{
		Implementation:    "GoNode",
		RuntimeSurface:    surface.RuntimeSurface(),
		PeerMode:          peerMode,
		Peer:              peer,
		TargetHeight:      target,
		HeaderHeight:      storedHeight,
		StoredBlockHeight: storedHeight,
		ValidatedHeight:   connectSummary.ValidatedHeight,
		SyncStatus:        connectSummary.SyncStatus,
		CurrentBlocker:    connectSummary.CurrentBlocker,
		BinaryGateStatus:  "not_attempted",
		StartedAt:         started.Format(time.RFC3339),
		UpdatedAt:         time.Now().UTC().Format(time.RFC3339),
		BlocksFetched:     fetched,
	}
}

func mergeTiming(dst *connect.TimingSummary, src connect.TimingSummary) {
	if dst.StageTotalsMillis == nil {
		dst.StageTotalsMillis = map[string]int64{}
	}
	for stage, millis := range src.StageTotalsMillis {
		dst.StageTotalsMillis[stage] += millis
	}
	dst.SlowBlocks = append(dst.SlowBlocks, src.SlowBlocks...)
	sort.Slice(dst.SlowBlocks, func(i, j int) bool {
		return dst.SlowBlocks[i].Millis > dst.SlowBlocks[j].Millis
	})
	if len(dst.SlowBlocks) > 10 {
		dst.SlowBlocks = dst.SlowBlocks[:10]
	}
}

func prefetchDepth() int {
	value := 4
	if raw := os.Getenv("GOBITNODE_BLOCK_PREFETCH_DEPTH"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			value = parsed
		}
	}
	if value > 64 {
		return 64
	}
	return value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func targetLabel(target int) string {
	switch target {
	case 5000:
		return "5k"
	case 10000:
		return "10k"
	case 50000:
		return "50k"
	case 100000:
		return "100k"
	default:
		return ""
	}
}

func benchmarkKind(target int, byteSource string) string {
	if byteSource == "p2p" {
		switch target {
		case 5000:
			return "supporting_5k_p2p"
		case 10000:
			return "supporting_10k_p2p"
		case 50000:
			return "supporting_50k_p2p"
		case 100000:
			return "primary_100k_p2p"
		default:
			return "local_reference_p2p"
		}
	}
	switch target {
	case 5000:
		return "supporting_5k_durable_local_reference_replay"
	case 10000:
		return "supporting_10k_durable_local_reference_replay"
	case 50000:
		return "supporting_50k_durable_local_reference_replay"
	case 100000:
		return "primary_100k_durable_local_reference_replay"
	default:
		return "local_reference_replay"
	}
}

func supportingLane(target int, lane string) string {
	label := targetLabel(target)
	if label == "" {
		if lane == "p2p" {
			return "local_reference_p2p"
		}
		return "local_reference_rpc"
	}
	if lane == "p2p" {
		return "supporting_" + label + "_p2p"
	}
	return "supporting_" + label + "_rpc_replay"
}

func fail(doc map[string]any, message string) {
	doc["failures"] = append(failures(doc), message)
}

func failures(doc map[string]any) []string {
	raw, ok := doc["failures"].([]string)
	if !ok {
		return []string{}
	}
	return raw
}

func finish(doc map[string]any, resultPath string, exitCode int) {
	if resultPath != "" {
		if err := os.MkdirAll(filepath.Dir(resultPath), 0o755); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		payload, err := json.MarshalIndent(doc, "", "  ")
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if err := os.WriteFile(resultPath, append(payload, '\n'), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	payload, _ := json.MarshalIndent(doc, "", "  ")
	fmt.Println(string(payload))
	os.Exit(exitCode)
}

type profileRun struct {
	enabled bool
	cpu     *os.File
	paths   map[string]string
	stopped bool
}

func startProfiler(datadir string) *profileRun {
	run := &profileRun{}
	if os.Getenv("GOBITNODE_PROFILE") != "1" {
		return run
	}
	profileDir := filepath.Join(datadir, "profiles")
	if err := os.MkdirAll(profileDir, 0o755); err != nil {
		return run
	}
	run.enabled = true
	run.paths = map[string]string{
		"cpu":   filepath.Join(profileDir, "local_reference_cpu.pprof"),
		"heap":  filepath.Join(profileDir, "local_reference_heap.pprof"),
		"block": filepath.Join(profileDir, "local_reference_block.pprof"),
	}
	runtime.SetBlockProfileRate(1)
	cpu, err := os.Create(run.paths["cpu"])
	if err == nil {
		run.cpu = cpu
		_ = pprof.StartCPUProfile(cpu)
	}
	return run
}

func (p *profileRun) stop(doc map[string]any) {
	if p == nil || !p.enabled || p.stopped {
		return
	}
	p.stopped = true
	if p.cpu != nil {
		pprof.StopCPUProfile()
		_ = p.cpu.Close()
	}
	if heap, err := os.Create(p.paths["heap"]); err == nil {
		runtime.GC()
		_ = pprof.WriteHeapProfile(heap)
		_ = heap.Close()
	}
	if block, err := os.Create(p.paths["block"]); err == nil {
		_ = pprof.Lookup("block").WriteTo(block, 0)
		_ = block.Close()
	}
	runtime.SetBlockProfileRate(0)
	doc["profile_paths"] = p.paths
}
