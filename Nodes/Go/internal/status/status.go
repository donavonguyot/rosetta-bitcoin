package status

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"rosettabitcoin/nodes/go/internal/crypto"
	"rosettabitcoin/nodes/go/internal/storage"
	"rosettabitcoin/nodes/go/internal/surface"
)

type Document struct {
	OK                     bool                   `json:"ok"`
	NodeID                 string                 `json:"node_id"`
	Implementation         string                 `json:"implementation"`
	RuntimeSurface         string                 `json:"runtime_surface"`
	UtxoAccounting         string                 `json:"utxo_accounting_policy"`
	RuntimeStatus          string                 `json:"runtime_status"`
	Chain                  string                 `json:"chain"`
	Network                string                 `json:"network"`
	Datadir                string                 `json:"datadir"`
	BinaryGateStatus       string                 `json:"binary_gate_status"`
	SyncStatus             string                 `json:"sync_status"`
	HeaderHeight           int                    `json:"header_height"`
	HeaderHash             string                 `json:"header_hash"`
	StoredBlockHeight      int                    `json:"stored_block_height"`
	StoredBlockHash        string                 `json:"stored_block_hash"`
	ValidatedHeight        int                    `json:"validated_height"`
	ValidatedHash          string                 `json:"validated_hash"`
	ChainstateBackend      string                 `json:"chainstate_backend"`
	ChainstateBackendPath  string                 `json:"chainstate_backend_path"`
	ChainstateGenerationID string                 `json:"chainstate_generation_id"`
	ChainstateStatus       string                 `json:"chainstate_status"`
	ChainstateUTXOCount    int                    `json:"chainstate_utxo_count"`
	StorageCodecVersion    int                    `json:"storage_codec_version"`
	RocksDBTuning          string                 `json:"rocksdb_tuning"`
	RocksDBWALDisabled     bool                   `json:"rocksdb_wal_disabled"`
	NativeCryptoBackend    string                 `json:"native_crypto_backend"`
	NativeCryptoAvailable  bool                   `json:"native_crypto_available"`
	TaprootTweakBackend    string                 `json:"taproot_tweak_backend"`
	BlockGapCount          int                    `json:"block_gap_count"`
	CurrentBlocker         map[string]any         `json:"current_blocker"`
	LastError              string                 `json:"last_error"`
	ActiveWriterPID        *int                   `json:"active_writer_pid"`
	LockStatus             string                 `json:"lock_status"`
	UpdatedAt              string                 `json:"updated_at"`
	Extra                  map[string]interface{} `json:"extra,omitempty"`
}

func Build(datadir string) (Document, error) {
	meta, err := storage.ReadMetadata(datadir)
	if err != nil {
		meta = storage.Metadata{
			NodeID:              "gobitnode-uninitialized",
			GenerationID:        "",
			Chain:               "testnet4",
			SyncStatus:          "starting",
			ChainstateStatus:    "missing",
			ChainstateBackend:   "rocksdb",
			ValidatedHeight:     0,
			ValidatedHash:       "",
			HeaderHeight:        0,
			StoredBlockHeight:   0,
			ChainstateUTXOCount: 0,
			StorageCodecVersion: 2,
			UpdatedAt:           time.Now().UTC().Format(time.RFC3339),
		}
	}
	info := crypto.Info()
	lockStatus, pid := lockInfo(filepath.Join(datadir, ".gobitnode.lock"))
	binary := "not_attempted"
	if meta.CurrentBlocker != nil {
		binary = "failed"
	}
	return Document{
		OK:                     true,
		NodeID:                 meta.NodeID,
		Implementation:         "GoNode",
		RuntimeSurface:         surface.RuntimeSurface(),
		UtxoAccounting:         "core_spendable_v1",
		RuntimeStatus:          map[bool]string{true: "running", false: "not_running"}[pid != nil],
		Chain:                  meta.Chain,
		Network:                meta.Chain,
		Datadir:                datadir,
		BinaryGateStatus:       binary,
		SyncStatus:             meta.SyncStatus,
		HeaderHeight:           meta.HeaderHeight,
		HeaderHash:             meta.HeaderHash,
		StoredBlockHeight:      meta.StoredBlockHeight,
		StoredBlockHash:        meta.StoredBlockHash,
		ValidatedHeight:        meta.ValidatedHeight,
		ValidatedHash:          meta.ValidatedHash,
		ChainstateBackend:      meta.ChainstateBackend,
		ChainstateBackendPath:  filepath.Join(datadir, "chainstate-rocksdb"),
		ChainstateGenerationID: meta.GenerationID,
		ChainstateStatus:       meta.ChainstateStatus,
		ChainstateUTXOCount:    meta.ChainstateUTXOCount,
		StorageCodecVersion:    meta.StorageCodecVersion,
		RocksDBTuning:          meta.RocksDBTuning,
		RocksDBWALDisabled:     meta.RocksDBWALDisabled,
		NativeCryptoBackend:    info.ECDSABackend,
		NativeCryptoAvailable:  info.NativeAvailable,
		TaprootTweakBackend:    info.TaprootTweakBackend,
		BlockGapCount:          max(0, meta.StoredBlockHeight-meta.ValidatedHeight),
		CurrentBlocker:         meta.CurrentBlocker,
		LastError:              meta.LastError,
		ActiveWriterPID:        pid,
		LockStatus:             lockStatus,
		UpdatedAt:              meta.UpdatedAt,
	}, nil
}

func Encode(doc Document) ([]byte, error) {
	return json.MarshalIndent(doc, "", "  ")
}

func lockInfo(path string) (string, *int) {
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 {
		return "unlocked", nil
	}
	return "locked", nil
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
