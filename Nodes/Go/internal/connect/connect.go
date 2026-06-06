package connect

import (
	"fmt"
	"sort"
	"time"

	"rosettabitcoin/nodes/go/internal/refsync"
	"rosettabitcoin/nodes/go/internal/script"
	"rosettabitcoin/nodes/go/internal/storage"
	"rosettabitcoin/nodes/go/internal/surface"
	txtypes "rosettabitcoin/nodes/go/internal/tx"
)

type Options struct {
	DataDir  string
	Target   int
	Progress int
	Quiet    bool
}

type Summary struct {
	Implementation     string         `json:"implementation"`
	RuntimeSurface     string         `json:"runtime_surface"`
	UtxoAccounting     string         `json:"utxo_accounting_policy"`
	Mode               string         `json:"mode"`
	TargetHeight       int            `json:"target_height"`
	HeaderHeight       int            `json:"header_height"`
	StoredBlockHeight  int            `json:"stored_block_height"`
	ValidatedHeight    int            `json:"validated_height"`
	ValidatedHash      string         `json:"validated_hash"`
	ChainstateUTXOs    int            `json:"chainstate_utxo_count"`
	SyncStatus         string         `json:"sync_status"`
	CurrentBlocker     map[string]any `json:"current_blocker"`
	ReachedTarget      bool           `json:"reached_target"`
	StartedAt          string         `json:"started_at"`
	UpdatedAt          string         `json:"updated_at"`
	BlocksConnected    int            `json:"blocks_connected"`
	ScriptRunnerMode   string         `json:"script_runner_mode"`
	ScriptThreads      int            `json:"script_threads"`
	CryptoContextMode  string         `json:"crypto_context_mode"`
	StorageCodec       int            `json:"storage_codec_version"`
	RocksDBTuning      string         `json:"rocksdb_tuning"`
	RocksDBWALDisabled bool           `json:"rocksdb_wal_disabled"`
	TimingSummary      TimingSummary  `json:"timing_summary"`
}

func Run(opts Options) (Summary, error) {
	if opts.Target < 0 {
		return Summary{}, fmt.Errorf("target must be >= 0")
	}
	if opts.Progress <= 0 {
		opts.Progress = 100
	}
	store, err := storage.Open(opts.DataDir)
	if err != nil {
		return Summary{}, err
	}
	defer store.Close()
	return RunStore(store, opts)
}

func RunStore(store *storage.Store, opts Options) (Summary, error) {
	if opts.Target < 0 {
		return Summary{}, fmt.Errorf("target must be >= 0")
	}
	if opts.Progress <= 0 {
		opts.Progress = 100
	}
	meta, err := store.Metadata()
	if err != nil {
		return Summary{}, err
	}
	if opts.Target > meta.StoredBlockHeight {
		return Summary{}, fmt.Errorf("target %d exceeds stored block height %d", opts.Target, meta.StoredBlockHeight)
	}
	started := time.Now().UTC().Format(time.RFC3339)
	startHeight := meta.ValidatedHeight + 1
	prevHash := meta.ValidatedHash
	if meta.ValidatedHeight == 0 && meta.ValidatedHash == "" {
		startHeight = 0
	}
	utxoCount := meta.ChainstateUTXOCount
	connected := 0
	timing := newTimingCollector()
	runner := newScriptRunner()
	defer runner.close()
	timing.setCount("script_threads", int64(runner.threads()))
	for height := startHeight; height <= opts.Target; height++ {
		blockStarted := time.Now()
		var raw []byte
		if err := timing.measure("block_read", func() error {
			var readErr error
			raw, readErr = store.ReadBlock(height)
			return readErr
		}); err != nil {
			return Summary{}, fmt.Errorf("height %d: read stored block: %w", height, err)
		}
		expectedPrev := prevHash
		if height == 0 {
			expectedPrev = ""
		}
		var info refsync.BlockInfo
		var txs []txtypes.Transaction
		if err := timing.measure("block_parse_validate", func() error {
			var decodeErr error
			info, _, decodeErr = refsync.DecodeBlock(raw, "", expectedPrev)
			if decodeErr != nil {
				return decodeErr
			}
			var parseErr error
			txs, parseErr = txtypes.ParseBlockTransactions(raw)
			return parseErr
		}); err != nil {
			return Summary{}, fmt.Errorf("height %d: decode transactions: %w", height, err)
		}
		staged, spent, undo, spentScriptTypes, blocker, err := connectTransactions(store, runner, timing, height, info.Hash, txs)
		if err != nil {
			return Summary{}, fmt.Errorf("height %d: %w", height, err)
		}
		if blocker != nil {
			meta.CurrentBlocker = blocker
			meta.SyncStatus = "blocks_blocked"
			meta.ChainstateStatus = "blocked"
			meta.LastError = fmt.Sprint(blocker["failure"])
			meta.ChainstateUTXOCount = utxoCount
			if err := store.PutMetadata(meta); err != nil {
				return Summary{}, err
			}
			summary := summaryFrom(meta, opts.Target, started, connected, false, runner, store, timing)
			return summary, nil
		}
		prevHash = info.Hash
		connected++
		utxoCount = utxoCount - len(spent) + len(staged)
		meta.ValidatedHeight = height
		meta.ValidatedHash = info.Hash
		meta.ChainstateUTXOCount = utxoCount
		meta.CurrentBlocker = nil
		meta.LastError = ""
		meta.ChainstateStatus = "usable"
		meta.SyncStatus = syncStatus(height, meta.StoredBlockHeight)
		var commitTiming storage.CommitTiming
		if err := timing.measure("commit", func() error {
			var commitErr error
			commitTiming, commitErr = store.CommitBlockWithTiming(storage.BlockCommit{
				Height:   height,
				Hash:     info.Hash,
				Spent:    spent,
				Created:  staged,
				Undo:     undo,
				Metadata: meta,
			})
			return commitErr
		}); err != nil {
			return Summary{}, err
		}
		recordCommitTiming(timing, commitTiming)
		shape := blockShape(txs)
		shape.SpentPrevoutScriptTypes = spentScriptTypes
		timing.addCount("tx_count", int64(shape.TxCount))
		timing.addCount("input_count", int64(shape.VinCount))
		timing.recordBlock(height, time.Since(blockStarted), shape)
		if !opts.Quiet && (height%opts.Progress == 0 || height == opts.Target) {
			fmt.Printf("gobitnode-connect height=%d hash=%s txs=%d utxos=%d\n", height, info.Hash, info.TxCount, utxoCount)
		}
	}
	return summaryFrom(meta, opts.Target, started, connected, true, runner, store, timing), nil
}

func blockShape(txs []txtypes.Transaction) SlowBlock {
	shape := SlowBlock{
		TxCount:           len(txs),
		InputShapeCounts:  map[string]int{},
		OutputScriptTypes: map[string]int{},
	}
	for _, tx := range txs {
		shape.VinCount += len(tx.Inputs)
		shape.VoutCount += len(tx.Outputs)
		for inputIndex, input := range tx.Inputs {
			if tx.IsCoinbase() && inputIndex == 0 {
				shape.InputShapeCounts["coinbase"]++
				continue
			}
			shape.ScriptInputCount++
			if inputIndex < len(tx.Witness) && len(tx.Witness[inputIndex]) > 0 {
				shape.InputShapeCounts["witness"]++
			} else if len(input.ScriptSig) > 0 {
				shape.InputShapeCounts["legacy_scriptsig"]++
			} else {
				shape.InputShapeCounts["empty"]++
			}
		}
		for _, output := range tx.Outputs {
			shape.OutputScriptTypes[scriptType(output.ScriptPubKey)]++
		}
	}
	return shape
}

func scriptType(script []byte) string {
	switch {
	case len(script) == 0:
		return "empty"
	case script[0] == 0x6a:
		return "op_return"
	case len(script) == 25 && script[0] == 0x76 && script[1] == 0xa9 && script[2] == 0x14 && script[23] == 0x88 && script[24] == 0xac:
		return "p2pkh"
	case len(script) == 23 && script[0] == 0xa9 && script[1] == 0x14 && script[22] == 0x87:
		return "p2sh"
	case len(script) == 22 && script[0] == 0x00 && script[1] == 0x14:
		return "p2wpkh"
	case len(script) == 34 && script[0] == 0x00 && script[1] == 0x20:
		return "p2wsh"
	case len(script) == 34 && script[0] == 0x51 && script[1] == 0x20:
		return "p2tr"
	default:
		return "other"
	}
}

func shouldPrecomputeSighashes(prevouts []script.SpentPrevout) bool {
	for _, prevout := range prevouts {
		switch scriptType(prevout.ScriptPubKey) {
		case "p2sh", "p2wpkh", "p2wsh", "p2tr":
			return true
		}
	}
	return false
}

func connectTransactions(store *storage.Store, runner *scriptRunner, timing *timingCollector, height int, blockHash string, txs []txtypes.Transaction) ([]storage.UTXO, []storage.OutPoint, []storage.UndoEntry, map[string]int, map[string]any, error) {
	if len(txs) == 0 || !txs[0].IsCoinbase() {
		return nil, nil, nil, nil, blocker(height, blockHash, "", 0, "block_first_transaction_not_coinbase", "block does not begin with a coinbase transaction"), nil
	}
	expectedSpends, expectedCreates := blockMutationShape(txs)
	view := newBlockView(expectedSpends, expectedCreates)
	prevouts := gatherPrevouts(txs)
	var loaded map[storage.OutPoint]*storage.UTXO
	if err := timing.measure("prevout_batch_load", func() error {
		var loadErr error
		var readTiming storage.UTXOReadTiming
		loaded, readTiming, loadErr = store.GetUTXOsWithTiming(prevouts)
		timing.addMillis("prevout_multi_get_call", readTiming.MultiGetMillis)
		timing.addMillis("prevout_utxo_decode", readTiming.DecodeMillis)
		timing.addMillis("prevout_legacy_fallback_get", readTiming.LegacyFallbackMillis)
		timing.addCount("utxo_lookup_count", readTiming.LookupCount)
		timing.addCount("utxo_key_bytes", readTiming.KeyBytes)
		timing.addCount("utxo_value_bytes", readTiming.ValueBytes)
		return loadErr
	}); err != nil {
		return nil, nil, nil, nil, nil, err
	}
	view.loaded = loaded
	jobs := make([]scriptJob, 0, expectedSpends)
	for txIndex := range txs {
		tx := &txs[txIndex]
		txidInternal := txtypes.DoubleSHA(txtypes.Serialize(*tx, false))
		txid := txtypes.DisplayHash(txidInternal)
		if txIndex == 0 {
			if height == 0 {
				continue
			}
			outs := outputsFor(height, tx, txidInternal, true)
			view.addCreated(outs)
			continue
		}
		if len(tx.Inputs) == 0 {
			return nil, nil, nil, nil, blocker(height, blockHash, txid, 0, "transaction_without_inputs", "non-coinbase transaction has no inputs"), nil
		}
		spentPrevouts := make([]script.SpentPrevout, len(tx.Inputs))
		inputUtxos := make([]storage.UTXO, len(tx.Inputs))
		inputOutpoints := make([]storage.OutPoint, len(tx.Inputs))
		inputSeen := make(map[storage.OutPoint]bool, len(tx.Inputs))
		for inputIndex, input := range tx.Inputs {
			outpoint := outpointFromInput(input)
			if inputSeen[outpoint] || view.isSpent(outpoint) {
				return nil, nil, nil, nil, blockerWithPrevout(height, blockHash, txid, inputIndex, input, storage.UTXO{}, "duplicate_spend", "duplicate spend inside block"), nil
			}
			inputSeen[outpoint] = true
			utxo, ok := view.find(outpoint)
			if !ok {
				return nil, nil, nil, nil, blocker(height, blockHash, txid, inputIndex, "missing_utxo", "Go connect replay could not find the spent prevout"), nil
			}
			if utxo.Coinbase && height-utxo.Height < 100 {
				return nil, nil, nil, nil, blockerWithPrevout(height, blockHash, txid, inputIndex, input, utxo, "coinbase_maturity", "coinbase spend before 100 confirmations"), nil
			}
			spk, err := utxo.ScriptBytes()
			if err != nil {
				return nil, nil, nil, nil, nil, err
			}
			spentPrevouts[inputIndex] = script.SpentPrevout{Amount: utxo.Value, ScriptPubKey: spk}
			inputUtxos[inputIndex] = utxo
			inputOutpoints[inputIndex] = outpoint
			view.addSpentScriptType(spk)
		}
		var precompute *script.SighashPrecompute
		if shouldPrecomputeSighashes(spentPrevouts) {
			precompute = script.NewSighashPrecompute(*tx, spentPrevouts)
		}
		options := make([]script.VerifyInputOptions, len(tx.Inputs))
		for inputIndex := range tx.Inputs {
			options[inputIndex] = script.VerifyInputOptions{
				ScriptPubKey:      spentPrevouts[inputIndex].ScriptPubKey,
				Amount:            spentPrevouts[inputIndex].Amount,
				SpentPrevouts:     spentPrevouts,
				SighashPrecompute: precompute,
			}
			jobs = append(jobs, scriptJob{
				tx:         tx,
				txid:       txid,
				inputIndex: inputIndex,
				utxo:       &inputUtxos[inputIndex],
				options:    &options[inputIndex],
			})
			view.markSpent(inputOutpoints[inputIndex], inputUtxos[inputIndex])
		}
		outs := outputsFor(height, tx, txidInternal, false)
		view.addCreated(outs)
	}
	var verifyFailure *scriptFailure
	verifyStart := time.Now()
	verifyFailure, verifyStats := runner.verify(jobs)
	verifyWall := time.Since(verifyStart)
	timing.addStage("script_verify", verifyWall)
	timing.addStage("script_wall_ms", verifyWall)
	timing.addStage("script_verify_worker_cpu", verifyStats.workerTime)
	timing.addStage("script_worker_cpu_ms", verifyStats.workerTime)
	timing.addCount("runner_batches", verifyStats.batches)
	timing.addCount("script_jobs", int64(len(jobs)))
	if verifyFailure != nil {
		err := verifyFailure.err
		input := verifyFailure.job.tx.Inputs[verifyFailure.job.inputIndex]
		return nil, nil, nil, nil, blockerWithPrevout(height, blockHash, verifyFailure.job.txid, verifyFailure.job.inputIndex, input, *verifyFailure.job.utxo, "script_verify_failed", err.Error()), nil
	}
	var created []storage.UTXO
	var spent []storage.OutPoint
	var undo []storage.UndoEntry
	timing.measure("utxo_apply", func() error {
		created = view.createdUTXOs()
		spent = view.externalSpends()
		undo = view.undoEntries()
		timing.addCount("created_utxos", int64(len(created)))
		timing.addCount("spent_external", int64(len(spent)))
		timing.addCount("same_block_spends", int64(view.sameBlockSpends))
		return nil
	})
	return created, spent, undo, view.spentPrevoutScriptTypes, nil, nil
}

func outputsFor(height int, transaction *txtypes.Transaction, txidInternal []byte, coinbase bool) []storage.UTXO {
	utxos := make([]storage.UTXO, 0, len(transaction.Outputs))
	for vout, output := range transaction.Outputs {
		if !isSpendableOutput(output.ScriptPubKey) {
			continue
		}
		outpoint := storage.NewOutPointFromInternal(txidInternal, uint32(vout))
		utxos = append(utxos, storage.NewUTXO(outpoint, output.Value, output.ScriptPubKey, height, coinbase))
	}
	return utxos
}

func isSpendableOutput(scriptPubKey []byte) bool {
	return len(scriptPubKey) > 0 && scriptPubKey[0] != 0x6a
}

type blockView struct {
	loaded                  map[storage.OutPoint]*storage.UTXO
	created                 []createdEntry
	createdIndex            map[storage.OutPoint]int
	spent                   map[storage.OutPoint]bool
	externalSpent           []storage.OutPoint
	undo                    []storage.UndoEntry
	sameBlockSpends         int
	spentPrevoutScriptTypes map[string]int
}

type createdEntry struct {
	outpoint storage.OutPoint
	utxo     storage.UTXO
	spent    bool
}

func newBlockView(expectedSpends int, expectedCreates int) *blockView {
	return &blockView{
		loaded:                  make(map[storage.OutPoint]*storage.UTXO, expectedSpends),
		created:                 make([]createdEntry, 0, expectedCreates),
		createdIndex:            make(map[storage.OutPoint]int, expectedCreates),
		spent:                   make(map[storage.OutPoint]bool, expectedSpends),
		externalSpent:           make([]storage.OutPoint, 0, expectedSpends),
		undo:                    make([]storage.UndoEntry, 0, expectedSpends),
		spentPrevoutScriptTypes: make(map[string]int),
	}
}

func (v *blockView) addCreated(utxos []storage.UTXO) {
	for _, utxo := range utxos {
		outpoint := utxo.OutPoint()
		if index, ok := v.createdIndex[outpoint]; ok {
			v.created[index] = createdEntry{outpoint: outpoint, utxo: utxo}
			continue
		}
		v.createdIndex[outpoint] = len(v.created)
		v.created = append(v.created, createdEntry{outpoint: outpoint, utxo: utxo})
	}
}

func (v *blockView) find(outpoint storage.OutPoint) (storage.UTXO, bool) {
	if v.spent[outpoint] {
		return storage.UTXO{}, false
	}
	if index, ok := v.createdIndex[outpoint]; ok {
		entry := v.created[index]
		if entry.spent {
			return storage.UTXO{}, false
		}
		return entry.utxo, true
	}
	utxo := v.loaded[outpoint]
	if utxo == nil {
		return storage.UTXO{}, false
	}
	return *utxo, true
}

func (v *blockView) isSpent(outpoint storage.OutPoint) bool {
	return v.spent[outpoint]
}

func (v *blockView) markSpent(outpoint storage.OutPoint, utxo storage.UTXO) {
	v.spent[outpoint] = true
	if index, ok := v.createdIndex[outpoint]; ok {
		v.created[index].spent = true
		v.sameBlockSpends++
		return
	}
	v.externalSpent = append(v.externalSpent, outpoint)
	v.undo = append(v.undo, storage.UndoEntry{Outpoint: outpoint, UTXO: utxo})
}

func (v *blockView) addSpentScriptType(scriptPubKey []byte) {
	v.spentPrevoutScriptTypes[scriptType(scriptPubKey)]++
}

func (v *blockView) createdUTXOs() []storage.UTXO {
	out := make([]storage.UTXO, 0, len(v.created))
	for _, entry := range v.created {
		if !entry.spent {
			out = append(out, entry.utxo)
		}
	}
	return out
}

func (v *blockView) externalSpends() []storage.OutPoint {
	return v.externalSpent
}

func (v *blockView) undoEntries() []storage.UndoEntry {
	return v.undo
}

func gatherPrevouts(txs []txtypes.Transaction) []storage.OutPoint {
	expectedSpends, _ := blockMutationShape(txs)
	seen := make(map[storage.OutPoint]bool, expectedSpends)
	out := make([]storage.OutPoint, 0, expectedSpends)
	for txIndex, tx := range txs {
		if txIndex == 0 {
			continue
		}
		for _, input := range tx.Inputs {
			outpoint := outpointFromInput(input)
			if seen[outpoint] {
				continue
			}
			seen[outpoint] = true
			out = append(out, outpoint)
		}
	}
	sortOutpoints(out)
	return out
}

func sortOutpoints(outpoints []storage.OutPoint) {
	sort.Slice(outpoints, func(i, j int) bool {
		return outpoints[i].Less(outpoints[j])
	})
}

func outpointFromInput(input txtypes.TxIn) storage.OutPoint {
	return storage.NewOutPointFromInternal(input.PreviousOutput.Hash, input.PreviousOutput.Index)
}

func blockMutationShape(txs []txtypes.Transaction) (int, int) {
	spends := 0
	creates := 0
	for txIndex, tx := range txs {
		if txIndex != 0 {
			spends += len(tx.Inputs)
		}
		for _, output := range tx.Outputs {
			if isSpendableOutput(output.ScriptPubKey) {
				creates++
			}
		}
	}
	return spends, creates
}

func recordCommitTiming(timing *timingCollector, commitTiming storage.CommitTiming) {
	timing.addStage("utxo_key_encode", commitTiming.UTXOKeyEncode)
	timing.addStage("utxo_delete_prepare", commitTiming.UTXODeletePrepare)
	timing.addStage("utxo_put_prepare", commitTiming.UTXOPutPrepare)
	timing.addStage("undo_put_prepare", commitTiming.UndoPutPrepare)
	timing.addStage("metadata_put_prepare", commitTiming.MetadataPutPrepare)
	timing.addStage("rocksdb_write", commitTiming.RocksDBWrite)
}

func blocker(height int, blockHash string, txid string, input int, missingRule string, failure string) map[string]any {
	return map[string]any{
		"height":       height,
		"block_hash":   blockHash,
		"txid":         txid,
		"input":        input,
		"failure":      failure,
		"missing_rule": missingRule,
		"source":       "gobitnode-connect",
		"created_at":   time.Now().UTC().Format(time.RFC3339),
	}
}

func blockerWithPrevout(height int, blockHash string, txid string, inputIndex int, input txtypes.TxIn, utxo storage.UTXO, missingRule string, failure string) map[string]any {
	value := blocker(height, blockHash, txid, inputIndex, missingRule, failure)
	value["prev_txid"] = txtypes.DisplayHash(input.PreviousOutput.Hash)
	value["prev_vout"] = input.PreviousOutput.Index
	value["spent_script_pubkey"] = utxo.ScriptHex()
	value["spent_value"] = utxo.Value
	value["spent_height"] = utxo.Height
	value["spent_coinbase"] = utxo.Coinbase
	return value
}

func syncStatus(validated int, stored int) string {
	if validated >= stored {
		return "blocks_current"
	}
	return "blocks_syncing"
}

func summaryFrom(meta storage.Metadata, target int, started string, connected int, reached bool, runner *scriptRunner, store *storage.Store, timing *timingCollector) Summary {
	return Summary{
		Implementation:     "GoNode",
		RuntimeSurface:     surface.RuntimeSurface(),
		UtxoAccounting:     "core_spendable_v1",
		Mode:               "stored_block_connect",
		TargetHeight:       target,
		HeaderHeight:       meta.HeaderHeight,
		StoredBlockHeight:  meta.StoredBlockHeight,
		ValidatedHeight:    meta.ValidatedHeight,
		ValidatedHash:      meta.ValidatedHash,
		ChainstateUTXOs:    meta.ChainstateUTXOCount,
		SyncStatus:         meta.SyncStatus,
		CurrentBlocker:     meta.CurrentBlocker,
		ReachedTarget:      reached,
		StartedAt:          started,
		UpdatedAt:          time.Now().UTC().Format(time.RFC3339),
		BlocksConnected:    connected,
		ScriptRunnerMode:   runner.mode(),
		ScriptThreads:      runner.threads(),
		CryptoContextMode:  runner.cryptoContextMode(),
		StorageCodec:       meta.StorageCodecVersion,
		RocksDBTuning:      store.TuningSummary(),
		RocksDBWALDisabled: store.WALDisabled(),
		TimingSummary:      timing.summary(),
	}
}
