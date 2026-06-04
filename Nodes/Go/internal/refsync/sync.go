package refsync

import (
	"fmt"
	"time"

	"rosettabitcoin/nodes/go/internal/storage"
	"rosettabitcoin/nodes/go/internal/surface"
)

type Options struct {
	DataDir  string
	Target   int
	RPCURL   string
	RPCUser  string
	RPCPass  string
	Progress int
}

type Summary struct {
	Implementation    string `json:"implementation"`
	RuntimeSurface    string `json:"runtime_surface"`
	PeerMode          string `json:"peer_mode"`
	Peer              string `json:"peer"`
	TargetHeight      int    `json:"target_height"`
	HeaderHeight      int    `json:"header_height"`
	StoredBlockHeight int    `json:"stored_block_height"`
	ValidatedHeight   int    `json:"validated_height"`
	SyncStatus        string `json:"sync_status"`
	CurrentBlocker    any    `json:"current_blocker"`
	BinaryGateStatus  string `json:"binary_gate_status"`
	StartedAt         string `json:"started_at"`
	UpdatedAt         string `json:"updated_at"`
	BlocksFetched     int    `json:"blocks_fetched"`
}

func Run(opts Options) (Summary, error) {
	if opts.Target < 0 {
		return Summary{}, fmt.Errorf("target must be >= 0")
	}
	if opts.Progress <= 0 {
		opts.Progress = 1000
	}
	client := &Client{URL: opts.RPCURL, User: opts.RPCUser, Password: opts.RPCPass}
	store, err := storage.Open(opts.DataDir)
	if err != nil {
		return Summary{}, err
	}
	defer store.Close()
	started := time.Now().UTC().Format(time.RFC3339)
	prev := ""
	var storedHash string
	for height := 0; height <= opts.Target; height++ {
		hash, err := client.BlockHash(height)
		if err != nil {
			return Summary{}, err
		}
		raw, err := client.RawBlock(hash)
		if err != nil {
			return Summary{}, err
		}
		info, err := ValidateBlock(raw, hash, prev)
		if err != nil {
			return Summary{}, fmt.Errorf("height %d: %w", height, err)
		}
		if err := store.RecordBlock(height, info.Hash, raw); err != nil {
			return Summary{}, err
		}
		prev = info.Hash
		storedHash = info.Hash
		if height%opts.Progress == 0 || height == opts.Target {
			meta := metadataFor(opts, height, storedHash, started)
			if err := store.PutMetadata(meta); err != nil {
				return Summary{}, err
			}
			fmt.Printf("gobitnode-sync height=%d hash=%s txs=%d\n", height, info.Hash, info.TxCount)
		}
	}
	meta := metadataFor(opts, opts.Target, storedHash, started)
	if err := store.PutMetadata(meta); err != nil {
		return Summary{}, err
	}
	return Summary{
		Implementation:    "GoNode",
		RuntimeSurface:    surface.RuntimeSurface(),
		PeerMode:          "local_reference_rpc",
		Peer:              opts.RPCURL,
		TargetHeight:      opts.Target,
		HeaderHeight:      opts.Target,
		StoredBlockHeight: opts.Target,
		ValidatedHeight:   0,
		SyncStatus:        "blocks_blocked",
		CurrentBlocker:    meta.CurrentBlocker,
		BinaryGateStatus:  "not_attempted",
		StartedAt:         started,
		UpdatedAt:         time.Now().UTC().Format(time.RFC3339),
		BlocksFetched:     opts.Target + 1,
	}, nil
}

func metadataFor(opts Options, height int, hash string, started string) storage.Metadata {
	return storage.Metadata{
		NodeID:            "gobitnode-local-reference-sync",
		GenerationID:      "go-reference-sync",
		Chain:             "testnet4",
		SyncStatus:        "blocks_blocked",
		ChainstateStatus:  "usable",
		ChainstateBackend: "rocksdb",
		ValidatedHeight:   0,
		ValidatedHash:     "",
		HeaderHeight:      height,
		HeaderHash:        hash,
		StoredBlockHeight: height,
		StoredBlockHash:   hash,
		CurrentBlocker: map[string]any{
			"height":       1,
			"failure":      "Go local-reference sync currently verifies headers, PoW, prev links, and merkle roots only",
			"missing_rule": "utxo_and_script_connect",
			"source":       "gobitnode-sync",
			"created_at":   started,
		},
		LastError: "",
	}
}
