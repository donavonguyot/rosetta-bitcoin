package storage

import (
	"encoding/json"
	"testing"
)

func TestBinaryUTXORoundTripAndGetMany(t *testing.T) {
	store, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	utxo := UTXO{
		TxID:              "0100000000000000000000000000000000000000000000000000000000000000",
		Vout:              2,
		Value:             12345,
		ScriptPubKeyBytes: []byte{0x51, 0x21, 0x02},
		Height:            9,
		Coinbase:          true,
	}
	if err := store.PutUTXO(utxo); err != nil {
		t.Fatal(err)
	}
	got, err := store.GetUTXO(utxo.TxID, utxo.Vout)
	if err != nil {
		t.Fatal(err)
	}
	if got == nil {
		t.Fatal("missing stored utxo")
	}
	script, err := got.ScriptBytes()
	if err != nil {
		t.Fatal(err)
	}
	if got.Value != utxo.Value || got.Height != utxo.Height || !got.Coinbase || string(script) != string(utxo.ScriptPubKeyBytes) {
		t.Fatalf("unexpected utxo round trip: %#v script=%x", got, script)
	}
	values, err := store.GetUTXOs([]OutPoint{
		{TxID: utxo.TxID, Vout: utxo.Vout},
		{TxID: "0200000000000000000000000000000000000000000000000000000000000000", Vout: 0},
	})
	if err != nil {
		t.Fatal(err)
	}
	if values[OutPoint{TxID: utxo.TxID, Vout: utxo.Vout}] == nil {
		t.Fatal("batch get missed present utxo")
	}
	if values[OutPoint{TxID: "0200000000000000000000000000000000000000000000000000000000000000", Vout: 0}] != nil {
		t.Fatal("batch get returned missing utxo")
	}
}

func TestBinaryOutPointKeyMatchesDisplayKeyAndJSON(t *testing.T) {
	txid := "010203040506070809101112131415161718191a1b1c1d1e1f20212223242526"
	display := NewOutPointFromDisplay(txid, 7)
	internal := NewOutPointFromInternal(display.hash[:], 7)
	if string(display.KeyBytes()) != string(internal.KeyBytes()) {
		t.Fatalf("binary and display keys differ: %x != %x", display.KeyBytes(), internal.KeyBytes())
	}
	var fixed [37]byte
	if !internal.WriteKeyBytes(fixed[:]) {
		t.Fatal("internal outpoint did not write fixed key")
	}
	if string(fixed[:]) != string(internal.KeyBytes()) {
		t.Fatalf("fixed key differs: %x != %x", fixed, internal.KeyBytes())
	}
	data, err := json.Marshal(internal)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"txid":"`+txid+`","vout":7}` {
		t.Fatalf("unexpected outpoint json: %s", data)
	}
	utxo := NewUTXO(internal, 99, []byte{0x51}, 11, false)
	data, err = json.Marshal(utxo)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"txid":"`+txid+`","vout":7,"value":99,"script_pubkey":"51","height":11,"coinbase":false}` {
		t.Fatalf("unexpected utxo json: %s", data)
	}
}

func TestBatchGetTimingCounters(t *testing.T) {
	store, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	outpoint := NewOutPointFromDisplay("0800000000000000000000000000000000000000000000000000000000000000", 3)
	utxo := NewUTXO(outpoint, 55, []byte{0x51}, 12, false)
	if err := store.PutUTXO(utxo); err != nil {
		t.Fatal(err)
	}
	missing := NewOutPointFromDisplay("0900000000000000000000000000000000000000000000000000000000000000", 1)
	values, timing, err := store.GetUTXOsWithTiming([]OutPoint{outpoint, missing})
	if err != nil {
		t.Fatal(err)
	}
	if values[outpoint] == nil || values[missing] != nil {
		t.Fatalf("unexpected batch results: %#v", values)
	}
	if timing.LookupCount != 2 || timing.KeyBytes != 74 || timing.ValueBytes == 0 {
		t.Fatalf("unexpected read timing counters: %#v", timing)
	}
}

func TestCommitBlockAtomicFailureLeavesTipAndUTXO(t *testing.T) {
	store, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	meta := Metadata{
		NodeID:            "test",
		GenerationID:      "test-generation",
		Chain:             "testnet4",
		SyncStatus:        "blocks_syncing",
		ChainstateStatus:  "usable",
		ChainstateBackend: "rocksdb",
		ValidatedHeight:   0,
		ValidatedHash:     "genesis",
		StoredBlockHeight: 1,
	}
	if err := store.PutMetadata(meta); err != nil {
		t.Fatal(err)
	}
	existing := UTXO{
		TxID:              "0300000000000000000000000000000000000000000000000000000000000000",
		Vout:              0,
		Value:             1000,
		ScriptPubKeyBytes: []byte{0x51},
		Height:            0,
	}
	if err := store.PutUTXO(existing); err != nil {
		t.Fatal(err)
	}
	created := UTXO{
		TxID:              "0400000000000000000000000000000000000000000000000000000000000000",
		Vout:              1,
		Value:             900,
		ScriptPubKeyBytes: []byte{0x51},
		Height:            1,
	}
	store.FailNextCommitForTest()
	err = store.CommitBlock(BlockCommit{
		Height:  1,
		Hash:    "block1",
		Spent:   []OutPoint{{TxID: existing.TxID, Vout: existing.Vout}},
		Created: []UTXO{created},
		Undo:    []UndoEntry{{Outpoint: OutPoint{TxID: existing.TxID, Vout: existing.Vout}, UTXO: existing}},
		Metadata: Metadata{
			NodeID:              meta.NodeID,
			GenerationID:        meta.GenerationID,
			Chain:               meta.Chain,
			SyncStatus:          "blocks_current",
			ChainstateStatus:    "usable",
			ChainstateBackend:   "rocksdb",
			StoredBlockHeight:   1,
			ChainstateUTXOCount: 1,
		},
	})
	if err == nil {
		t.Fatal("expected injected commit failure")
	}
	stillExisting, err := store.GetUTXO(existing.TxID, existing.Vout)
	if err != nil {
		t.Fatal(err)
	}
	if stillExisting == nil {
		t.Fatal("existing utxo was deleted despite failed commit")
	}
	notCreated, err := store.GetUTXO(created.TxID, created.Vout)
	if err != nil {
		t.Fatal(err)
	}
	if notCreated != nil {
		t.Fatal("created utxo was written despite failed commit")
	}
	after, err := store.Metadata()
	if err != nil {
		t.Fatal(err)
	}
	if after.ValidatedHeight != 0 || after.ValidatedHash != "genesis" {
		t.Fatalf("metadata advanced despite failed commit: %#v", after)
	}
}

func TestCommitBlockWithTimingReportsPrepareAndWriteStages(t *testing.T) {
	store, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	meta := Metadata{
		NodeID:            "test",
		GenerationID:      "test-generation",
		Chain:             "testnet4",
		SyncStatus:        "blocks_syncing",
		ChainstateStatus:  "usable",
		ChainstateBackend: "rocksdb",
		ValidatedHeight:   0,
		ValidatedHash:     "genesis",
		StoredBlockHeight: 1,
	}
	if err := store.PutMetadata(meta); err != nil {
		t.Fatal(err)
	}
	existing := UTXO{
		TxID:              "0600000000000000000000000000000000000000000000000000000000000000",
		Vout:              0,
		Value:             1000,
		ScriptPubKeyBytes: []byte{0x51},
		Height:            0,
	}
	if err := store.PutUTXO(existing); err != nil {
		t.Fatal(err)
	}
	created := UTXO{
		TxID:              "0700000000000000000000000000000000000000000000000000000000000000",
		Vout:              1,
		Value:             900,
		ScriptPubKeyBytes: []byte{0x51},
		Height:            1,
	}
	timing, err := store.CommitBlockWithTiming(BlockCommit{
		Height:  1,
		Hash:    "block1",
		Spent:   []OutPoint{existing.OutPoint()},
		Created: []UTXO{created},
		Undo:    []UndoEntry{{Outpoint: existing.OutPoint(), UTXO: existing}},
		Metadata: Metadata{
			NodeID:              meta.NodeID,
			GenerationID:        meta.GenerationID,
			Chain:               meta.Chain,
			SyncStatus:          "blocks_current",
			ChainstateStatus:    "usable",
			ChainstateBackend:   "rocksdb",
			StoredBlockHeight:   1,
			ChainstateUTXOCount: 1,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if timing.UTXODeletePrepare <= 0 || timing.UTXOPutPrepare <= 0 || timing.UndoPutPrepare <= 0 || timing.MetadataPutPrepare <= 0 || timing.RocksDBWrite <= 0 {
		t.Fatalf("missing commit timing: %#v", timing)
	}
}

func TestBinaryCodecGoldenVector(t *testing.T) {
	utxo := UTXO{
		TxID:              "0500000000000000000000000000000000000000000000000000000000000000",
		Vout:              0,
		Value:             42,
		ScriptPubKeyBytes: []byte{0x51},
		Height:            7,
		Coinbase:          false,
	}
	encoded, err := encodeUTXO(utxo)
	if err != nil {
		t.Fatal(err)
	}
	want := []byte{0x02, 0x2a, 0, 0, 0, 0, 0, 0, 0, 0x07, 0, 0, 0, 0, 0x01, 0x51}
	if string(encoded) != string(want) {
		t.Fatalf("codec vector mismatch: got %x want %x", encoded, want)
	}
	decoded, err := decodeUTXO(utxo.TxID, utxo.Vout, encoded)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Value != utxo.Value || decoded.Height != utxo.Height || decoded.ScriptHex() != "51" {
		t.Fatalf("decoded mismatch: %#v", decoded)
	}
}
