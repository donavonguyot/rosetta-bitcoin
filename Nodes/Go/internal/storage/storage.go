package storage

/*
#cgo pkg-config: rocksdb
#include <rocksdb/c.h>
#include <stdlib.h>

static void rb_set_char_ptr(char **items, size_t index, char *value) {
	items[index] = value;
}

static char *rb_get_char_ptr(char **items, size_t index) {
	return items[index];
}

static void rb_set_size_t(size_t *items, size_t index, size_t value) {
	items[index] = value;
}

static size_t rb_get_size_t(size_t *items, size_t index) {
	return items[index];
}
*/
import "C"

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
	"unsafe"
)

const markerName = ".gobitnode_native_storage"
const codecVersion = 2

var binaryUTXOPrefix = []byte{'U'}

type Metadata struct {
	NodeID              string         `json:"node_id"`
	GenerationID        string         `json:"generation_id"`
	Chain               string         `json:"chain"`
	SyncStatus          string         `json:"sync_status"`
	ChainstateStatus    string         `json:"chainstate_status"`
	ChainstateBackend   string         `json:"chainstate_backend"`
	ValidatedHeight     int            `json:"validated_height"`
	ValidatedHash       string         `json:"validated_hash"`
	HeaderHeight        int            `json:"header_height"`
	HeaderHash          string         `json:"header_hash"`
	StoredBlockHeight   int            `json:"stored_block_height"`
	StoredBlockHash     string         `json:"stored_block_hash"`
	ChainstateUTXOCount int            `json:"chainstate_utxo_count"`
	StorageCodecVersion int            `json:"storage_codec_version"`
	RocksDBTuning       string         `json:"rocksdb_tuning"`
	RocksDBWALDisabled  bool           `json:"rocksdb_wal_disabled"`
	CurrentBlocker      map[string]any `json:"current_blocker"`
	LastError           string         `json:"last_error"`
	UpdatedAt           string         `json:"updated_at"`
}

type Store struct {
	db           *C.rocksdb_t
	ro           *C.rocksdb_readoptions_t
	wo           *C.rocksdb_writeoptions_t
	blockCache   *C.rocksdb_cache_t
	filterPolicy *C.rocksdb_filterpolicy_t
	tableOptions *C.rocksdb_block_based_table_options_t
	dataDir      string
	walDisabled  bool
	failCommit   bool
}

func Open(datadir string) (*Store, error) {
	if err := os.MkdirAll(filepath.Join(datadir, "blocks"), 0o755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(datadir, markerName), []byte("gobitnode native storage\n"), 0o644); err != nil {
		return nil, err
	}
	opts := C.rocksdb_options_create()
	defer C.rocksdb_options_destroy(opts)
	C.rocksdb_options_set_create_if_missing(opts, 1)
	C.rocksdb_options_set_write_buffer_size(opts, C.size_t(64*1024*1024))
	C.rocksdb_options_set_max_write_buffer_number(opts, 4)
	C.rocksdb_options_set_max_background_jobs(opts, 4)
	C.rocksdb_options_set_max_open_files(opts, -1)
	blockCacheMB := rocksDBBlockCacheMB()
	blockCache := C.rocksdb_cache_create_lru(C.size_t(blockCacheMB * 1024 * 1024))
	filterPolicy := C.rocksdb_filterpolicy_create_bloom(10)
	tableOptions := C.rocksdb_block_based_options_create()
	C.rocksdb_block_based_options_set_block_cache(tableOptions, blockCache)
	C.rocksdb_block_based_options_set_filter_policy(tableOptions, filterPolicy)
	C.rocksdb_block_based_options_set_cache_index_and_filter_blocks(tableOptions, 1)
	C.rocksdb_block_based_options_set_cache_index_and_filter_blocks_with_high_priority(tableOptions, 1)
	C.rocksdb_block_based_options_set_pin_l0_filter_and_index_blocks_in_cache(tableOptions, 1)
	C.rocksdb_options_set_block_based_table_factory(opts, tableOptions)
	cpath := C.CString(filepath.Join(datadir, "chainstate-rocksdb"))
	defer C.free(unsafe.Pointer(cpath))
	var cerr *C.char
	db := C.rocksdb_open(opts, cpath, &cerr)
	if cerr != nil {
		defer C.rocksdb_free(unsafe.Pointer(cerr))
		return nil, errors.New(C.GoString(cerr))
	}
	if db == nil {
		return nil, errors.New("rocksdb_open returned nil")
	}
	wo := C.rocksdb_writeoptions_create()
	walDisabled := os.Getenv("GOBITNODE_ROCKSDB_DISABLE_WAL") == "1"
	if walDisabled {
		C.rocksdb_writeoptions_disable_WAL(wo, 1)
	}
	return &Store{
		db:           db,
		ro:           C.rocksdb_readoptions_create(),
		wo:           wo,
		blockCache:   blockCache,
		filterPolicy: filterPolicy,
		tableOptions: tableOptions,
		dataDir:      datadir,
		walDisabled:  walDisabled,
	}, nil
}

func (s *Store) Close() {
	if s == nil {
		return
	}
	if s.ro != nil {
		C.rocksdb_readoptions_destroy(s.ro)
	}
	if s.wo != nil {
		C.rocksdb_writeoptions_destroy(s.wo)
	}
	if s.db != nil {
		C.rocksdb_close(s.db)
	}
}

func (s *Store) PutMetadata(meta Metadata) error {
	meta = s.normalizeMetadata(meta)
	meta.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	payload, err := json.Marshal(meta)
	if err != nil {
		return err
	}
	return s.put("meta", payload)
}

func (s *Store) RecordBlock(height int, hash string, raw []byte) error {
	if err := os.MkdirAll(filepath.Join(s.datadir(), "blocks"), 0o755); err != nil {
		return err
	}
	path := filepath.Join(s.datadir(), "blocks", "block_"+padHeight(height)+".dat")
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		return err
	}
	payload, _ := json.Marshal(map[string]any{
		"height": height,
		"hash":   hash,
		"path":   filepath.ToSlash(filepath.Join("blocks", filepath.Base(path))),
		"size":   len(raw),
	})
	return s.put("block-index:"+padHeight(height), payload)
}

func (s *Store) ReadBlock(height int) ([]byte, error) {
	path := filepath.Join(s.datadir(), "blocks", "block_"+padHeight(height)+".dat")
	return os.ReadFile(path)
}

type UTXO struct {
	TxID              string `json:"txid"`
	Vout              uint32 `json:"vout"`
	Value             int64  `json:"value"`
	ScriptPubKey      string `json:"script_pubkey"`
	ScriptPubKeyBytes []byte `json:"-"`
	Height            int    `json:"height"`
	Coinbase          bool   `json:"coinbase"`
	txidInternal      [32]byte
}

func NewUTXO(outpoint OutPoint, value int64, scriptPubKey []byte, height int, coinbase bool) UTXO {
	return UTXO{
		TxID:              outpoint.TxID,
		Vout:              outpoint.Vout,
		Value:             value,
		ScriptPubKeyBytes: append([]byte{}, scriptPubKey...),
		Height:            height,
		Coinbase:          coinbase,
		txidInternal:      outpoint.hash,
	}
}

func (s *Store) PutUTXO(utxo UTXO) error {
	payload, err := encodeUTXO(utxo)
	if err != nil {
		return err
	}
	return s.putBytes(utxo.OutPoint().KeyBytes(), payload)
}

func (s *Store) GetUTXO(txid string, vout uint32) (*UTXO, error) {
	outpoint := NewOutPointFromDisplay(txid, vout)
	value, err := s.getBytes(outpoint.KeyBytes())
	if err != nil {
		return nil, err
	}
	if value == nil {
		value, err = s.get(legacyUTXOKey(outpoint.DisplayTxID(), outpoint.Vout))
	}
	if err != nil {
		return nil, err
	}
	if value == nil {
		return nil, nil
	}
	utxo, err := decodeUTXOForOutPoint(outpoint, value)
	if err != nil {
		return nil, err
	}
	return &utxo, nil
}

type OutPoint struct {
	TxID string `json:"txid"`
	Vout uint32 `json:"vout"`
	hash [32]byte
}

func NewOutPointFromDisplay(txid string, vout uint32) OutPoint {
	raw, err := internalHash(txid)
	if err != nil {
		return OutPoint{TxID: txid, Vout: vout}
	}
	var hash [32]byte
	copy(hash[:], raw)
	return OutPoint{Vout: vout, hash: hash}
}

func NewOutPointFromInternal(hash []byte, vout uint32) OutPoint {
	var fixed [32]byte
	copy(fixed[:], hash)
	return OutPoint{Vout: vout, hash: fixed}
}

func (o OutPoint) DisplayTxID() string {
	if o.TxID != "" {
		return o.TxID
	}
	return displayHash(o.hash[:])
}

func (o OutPoint) KeyBytes() []byte {
	var key [37]byte
	if o.WriteKeyBytes(key[:]) {
		return append([]byte{}, key[:]...)
	}
	if o.TxID != "" {
		return utxoKeyBytes(o.TxID, o.Vout)
	}
	return append([]byte{}, key[:]...)
}

func (o OutPoint) WriteKeyBytes(dst []byte) bool {
	if len(dst) < 37 || (o.hash == ([32]byte{}) && o.TxID != "") {
		return false
	}
	dst[0] = binaryUTXOPrefix[0]
	copy(dst[1:33], o.hash[:])
	binary.LittleEndian.PutUint32(dst[33:37], o.Vout)
	return true
}

func (o OutPoint) Less(other OutPoint) bool {
	if cmp := bytes.Compare(o.hash[:], other.hash[:]); cmp != 0 {
		return cmp < 0
	}
	if o.TxID != other.TxID {
		return o.TxID < other.TxID
	}
	return o.Vout < other.Vout
}

func (o OutPoint) MarshalJSON() ([]byte, error) {
	type jsonOutPoint struct {
		TxID string `json:"txid"`
		Vout uint32 `json:"vout"`
	}
	return json.Marshal(jsonOutPoint{TxID: o.DisplayTxID(), Vout: o.Vout})
}

type UTXOReadTiming struct {
	MultiGetMillis       int64
	DecodeMillis         int64
	LegacyFallbackMillis int64
	LookupCount          int64
	KeyBytes             int64
	ValueBytes           int64
}

func (s *Store) GetUTXOs(outpoints []OutPoint) (map[OutPoint]*UTXO, error) {
	values, _, err := s.GetUTXOsWithTiming(outpoints)
	return values, err
}

func (s *Store) GetUTXOsWithTiming(outpoints []OutPoint) (map[OutPoint]*UTXO, UTXOReadTiming, error) {
	timing := UTXOReadTiming{}
	result := make(map[OutPoint]*UTXO, len(outpoints))
	if len(outpoints) == 0 {
		return result, timing, nil
	}
	start := time.Now()
	values, keyBytes, err := s.multiGetOutpoints(outpoints)
	timing.MultiGetMillis += time.Since(start).Milliseconds()
	timing.LookupCount += int64(len(outpoints))
	timing.KeyBytes += keyBytes
	if err != nil {
		return nil, timing, err
	}
	for i, value := range values {
		outpoint := outpoints[i]
		if value == nil {
			start = time.Now()
			legacy, err := s.get(legacyUTXOKey(outpoint.DisplayTxID(), outpoint.Vout))
			timing.LegacyFallbackMillis += time.Since(start).Milliseconds()
			if err != nil {
				return nil, timing, err
			}
			value = legacy
		}
		if value == nil {
			result[outpoint] = nil
			continue
		}
		timing.ValueBytes += int64(len(value))
		start = time.Now()
		utxo, err := decodeUTXOForOutPoint(outpoint, value)
		timing.DecodeMillis += time.Since(start).Milliseconds()
		if err != nil {
			return nil, timing, err
		}
		result[outpoint] = &utxo
	}
	return result, timing, nil
}

func (s *Store) DeleteUTXO(txid string, vout uint32) error {
	return s.deleteBytes(utxoKeyBytes(txid, vout))
}

func (s *Store) CountUTXOs() (int, error) {
	entries, err := s.utxoEntries()
	if err != nil {
		return 0, err
	}
	return len(entries), nil
}

func (s *Store) PruneUTXOsAtHeight(height int) (int, error) {
	entries, err := s.utxoEntries()
	if err != nil {
		return 0, err
	}
	removed := 0
	for _, entry := range entries {
		if entry.utxo.Height != height {
			continue
		}
		if err := s.deleteBytes(entry.key); err != nil {
			return removed, err
		}
		removed++
	}
	return removed, nil
}

func (s *Store) Metadata() (Metadata, error) {
	value, err := s.get("meta")
	if err != nil {
		return Metadata{}, err
	}
	if value == nil {
		return Metadata{}, errors.New("metadata missing")
	}
	var meta Metadata
	if err := json.Unmarshal(value, &meta); err != nil {
		return Metadata{}, err
	}
	return s.normalizeMetadata(meta), nil
}

type UndoEntry struct {
	Outpoint OutPoint `json:"outpoint"`
	UTXO     UTXO     `json:"utxo"`
}

type BlockCommit struct {
	Height   int
	Hash     string
	Spent    []OutPoint
	Created  []UTXO
	Undo     []UndoEntry
	Metadata Metadata
}

type CommitTiming struct {
	UTXOKeyEncode      time.Duration
	UTXODeletePrepare  time.Duration
	UTXOPutPrepare     time.Duration
	UndoPutPrepare     time.Duration
	MetadataPutPrepare time.Duration
	RocksDBWrite       time.Duration
}

func (s *Store) CommitBlock(commit BlockCommit) error {
	_, err := s.CommitBlockWithTiming(commit)
	return err
}

func (s *Store) CommitBlockWithTiming(commit BlockCommit) (CommitTiming, error) {
	timing := CommitTiming{}
	batch := C.rocksdb_writebatch_create()
	defer C.rocksdb_writebatch_destroy(batch)
	start := time.Now()
	for _, outpoint := range commit.Spent {
		keyStart := time.Now()
		var fixedKey [37]byte
		key := fixedKey[:]
		if !outpoint.WriteKeyBytes(key) {
			key = outpoint.KeyBytes()
		}
		timing.UTXOKeyEncode += time.Since(keyStart)
		writeBatchDelete(batch, key)
	}
	timing.UTXODeletePrepare += time.Since(start)
	start = time.Now()
	for _, utxo := range commit.Created {
		payload, err := encodeUTXO(utxo)
		if err != nil {
			return timing, err
		}
		keyStart := time.Now()
		outpoint := utxo.OutPoint()
		var fixedKey [37]byte
		key := fixedKey[:]
		if !outpoint.WriteKeyBytes(key) {
			key = outpoint.KeyBytes()
		}
		timing.UTXOKeyEncode += time.Since(keyStart)
		writeBatchPut(batch, key, payload)
	}
	timing.UTXOPutPrepare += time.Since(start)
	start = time.Now()
	undo, err := json.Marshal(commit.Undo)
	if err != nil {
		return timing, err
	}
	writeBatchPut(batch, []byte("undo:"+padHeight(commit.Height)), undo)
	timing.UndoPutPrepare += time.Since(start)
	start = time.Now()
	meta := s.normalizeMetadata(commit.Metadata)
	meta.ValidatedHeight = commit.Height
	meta.ValidatedHash = commit.Hash
	meta.CurrentBlocker = nil
	meta.LastError = ""
	meta.ChainstateStatus = "usable"
	meta.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	payload, err := json.Marshal(meta)
	if err != nil {
		return timing, err
	}
	writeBatchPut(batch, []byte("meta"), payload)
	timing.MetadataPutPrepare += time.Since(start)
	if s.failCommit {
		s.failCommit = false
		return timing, errors.New("injected commit failure")
	}
	start = time.Now()
	var cerr *C.char
	C.rocksdb_write(s.db, s.wo, batch, &cerr)
	timing.RocksDBWrite += time.Since(start)
	if cerr != nil {
		defer C.rocksdb_free(unsafe.Pointer(cerr))
		return timing, errors.New(C.GoString(cerr))
	}
	return timing, nil
}

func (s *Store) put(key string, value []byte) error {
	ckey := C.CString(key)
	defer C.free(unsafe.Pointer(ckey))
	var cvalue *C.char
	if len(value) > 0 {
		cvalue = (*C.char)(unsafe.Pointer(&value[0]))
	}
	var cerr *C.char
	C.rocksdb_put(s.db, s.wo, ckey, C.size_t(len(key)), cvalue, C.size_t(len(value)), &cerr)
	if cerr != nil {
		defer C.rocksdb_free(unsafe.Pointer(cerr))
		return errors.New(C.GoString(cerr))
	}
	return nil
}

type utxoEntry struct {
	key  []byte
	utxo UTXO
}

func (s *Store) utxoEntries() ([]utxoEntry, error) {
	it := C.rocksdb_create_iterator(s.db, s.ro)
	defer C.rocksdb_iter_destroy(it)
	entries := []utxoEntry{}
	for C.rocksdb_iter_seek_to_first(it); C.rocksdb_iter_valid(it) != 0; C.rocksdb_iter_next(it) {
		var keyLen C.size_t
		keyData := C.rocksdb_iter_key(it, &keyLen)
		key := C.GoBytes(unsafe.Pointer(keyData), C.int(keyLen))
		legacy := bytes.HasPrefix(key, []byte("utxo:"))
		binaryKey := len(key) == 37 && key[0] == binaryUTXOPrefix[0]
		if !legacy && !binaryKey {
			continue
		}
		var valueLen C.size_t
		valueData := C.rocksdb_iter_value(it, &valueLen)
		value := C.GoBytes(unsafe.Pointer(valueData), C.int(valueLen))
		txid := ""
		var vout uint32
		if binaryKey {
			txid = displayHash(key[1:33])
			vout = binary.LittleEndian.Uint32(key[33:37])
		}
		utxo, err := decodeUTXO(txid, vout, value)
		if err != nil {
			return nil, err
		}
		entries = append(entries, utxoEntry{key: key, utxo: utxo})
	}
	var cerr *C.char
	C.rocksdb_iter_get_error(it, &cerr)
	if cerr != nil {
		defer C.rocksdb_free(unsafe.Pointer(cerr))
		return nil, errors.New(C.GoString(cerr))
	}
	return entries, nil
}

func (s *Store) delete(key string) error {
	return s.deleteBytes([]byte(key))
}

func (s *Store) deleteBytes(key []byte) error {
	var ckey *C.char
	if len(key) > 0 {
		ckey = (*C.char)(unsafe.Pointer(&key[0]))
	}
	var cerr *C.char
	C.rocksdb_delete(s.db, s.wo, ckey, C.size_t(len(key)), &cerr)
	if cerr != nil {
		defer C.rocksdb_free(unsafe.Pointer(cerr))
		return errors.New(C.GoString(cerr))
	}
	return nil
}

func writeBatchPut(batch *C.rocksdb_writebatch_t, key []byte, value []byte) {
	var ckey *C.char
	if len(key) > 0 {
		ckey = (*C.char)(unsafe.Pointer(&key[0]))
	}
	var cvalue *C.char
	if len(value) > 0 {
		cvalue = (*C.char)(unsafe.Pointer(&value[0]))
	}
	C.rocksdb_writebatch_put(batch, ckey, C.size_t(len(key)), cvalue, C.size_t(len(value)))
}

func writeBatchDelete(batch *C.rocksdb_writebatch_t, key []byte) {
	var ckey *C.char
	if len(key) > 0 {
		ckey = (*C.char)(unsafe.Pointer(&key[0]))
	}
	C.rocksdb_writebatch_delete(batch, ckey, C.size_t(len(key)))
}

func (s *Store) multiGetOutpoints(outpoints []OutPoint) ([][]byte, int64, error) {
	if len(outpoints) == 0 {
		return [][]byte{}, 0, nil
	}
	count := len(outpoints)
	pointerBytes := C.size_t(count) * C.size_t(unsafe.Sizeof(uintptr(0)))
	sizeBytes := C.size_t(count) * C.size_t(unsafe.Sizeof(C.size_t(0)))
	keyPointerData := C.malloc(pointerBytes)
	keySizeData := C.malloc(sizeBytes)
	fixedKeyData := C.malloc(C.size_t(count * 37))
	valuePointerData := C.malloc(pointerBytes)
	valueSizeData := C.malloc(sizeBytes)
	errPointerData := C.malloc(pointerBytes)
	if keyPointerData == nil || keySizeData == nil || fixedKeyData == nil || valuePointerData == nil || valueSizeData == nil || errPointerData == nil {
		if keyPointerData != nil {
			C.free(keyPointerData)
		}
		if keySizeData != nil {
			C.free(keySizeData)
		}
		if fixedKeyData != nil {
			C.free(fixedKeyData)
		}
		if valuePointerData != nil {
			C.free(valuePointerData)
		}
		if valueSizeData != nil {
			C.free(valueSizeData)
		}
		if errPointerData != nil {
			C.free(errPointerData)
		}
		return nil, 0, errors.New("rocksdb multiget key allocation failed")
	}
	defer C.free(keyPointerData)
	defer C.free(keySizeData)
	defer C.free(fixedKeyData)
	defer C.free(valuePointerData)
	defer C.free(valueSizeData)
	defer C.free(errPointerData)
	fallbackKeys := []uintptr{}
	defer func() {
		for _, key := range fallbackKeys {
			C.free(unsafe.Pointer(key))
		}
	}()
	var keyBytes int64
	for i, outpoint := range outpoints {
		ptr := unsafe.Add(fixedKeyData, i*37)
		key := unsafe.Slice((*byte)(ptr), 37)
		if outpoint.WriteKeyBytes(key) {
			C.rb_set_char_ptr((**C.char)(keyPointerData), C.size_t(i), (*C.char)(ptr))
			C.rb_set_size_t((*C.size_t)(keySizeData), C.size_t(i), C.size_t(37))
			keyBytes += 37
			continue
		}
		encoded := outpoint.KeyBytes()
		copied := (*C.char)(C.CBytes(encoded))
		fallbackKeys = append(fallbackKeys, uintptr(unsafe.Pointer(copied)))
		C.rb_set_char_ptr((**C.char)(keyPointerData), C.size_t(i), copied)
		C.rb_set_size_t((*C.size_t)(keySizeData), C.size_t(i), C.size_t(len(encoded)))
		keyBytes += int64(len(encoded))
	}
	C.rocksdb_multi_get(
		s.db,
		s.ro,
		C.size_t(count),
		(**C.char)(keyPointerData),
		(*C.size_t)(keySizeData),
		(**C.char)(valuePointerData),
		(*C.size_t)(valueSizeData),
		(**C.char)(errPointerData),
	)
	out := make([][]byte, count)
	for i := range outpoints {
		err := C.rb_get_char_ptr((**C.char)(errPointerData), C.size_t(i))
		if err != nil {
			msg := C.GoString(err)
			C.rocksdb_free(unsafe.Pointer(err))
			return nil, keyBytes, errors.New(msg)
		}
		value := C.rb_get_char_ptr((**C.char)(valuePointerData), C.size_t(i))
		if value != nil {
			size := C.rb_get_size_t((*C.size_t)(valueSizeData), C.size_t(i))
			out[i] = C.GoBytes(unsafe.Pointer(value), C.int(size))
			C.rocksdb_free(unsafe.Pointer(value))
		}
	}
	return out, keyBytes, nil
}

func (s *Store) multiGet(keys [][]byte) ([][]byte, error) {
	if len(keys) == 0 {
		return [][]byte{}, nil
	}
	count := len(keys)
	pointerBytes := C.size_t(count) * C.size_t(unsafe.Sizeof(uintptr(0)))
	sizeBytes := C.size_t(count) * C.size_t(unsafe.Sizeof(C.size_t(0)))
	keyPointerData := C.malloc(pointerBytes)
	keySizeData := C.malloc(sizeBytes)
	valuePointerData := C.malloc(pointerBytes)
	valueSizeData := C.malloc(sizeBytes)
	errPointerData := C.malloc(pointerBytes)
	if keyPointerData == nil || keySizeData == nil || valuePointerData == nil || valueSizeData == nil || errPointerData == nil {
		if keyPointerData != nil {
			C.free(keyPointerData)
		}
		if keySizeData != nil {
			C.free(keySizeData)
		}
		if valuePointerData != nil {
			C.free(valuePointerData)
		}
		if valueSizeData != nil {
			C.free(valueSizeData)
		}
		if errPointerData != nil {
			C.free(errPointerData)
		}
		return nil, errors.New("rocksdb multiget allocation failed")
	}
	defer C.free(keyPointerData)
	defer C.free(keySizeData)
	defer C.free(valuePointerData)
	defer C.free(valueSizeData)
	defer C.free(errPointerData)
	copiedKeys := []uintptr{}
	for i, key := range keys {
		ptr := C.CBytes(key)
		copiedKeys = append(copiedKeys, uintptr(ptr))
		C.rb_set_char_ptr((**C.char)(keyPointerData), C.size_t(i), (*C.char)(ptr))
		C.rb_set_size_t((*C.size_t)(keySizeData), C.size_t(i), C.size_t(len(key)))
	}
	defer func() {
		for _, key := range copiedKeys {
			C.free(unsafe.Pointer(key))
		}
	}()
	C.rocksdb_multi_get(
		s.db,
		s.ro,
		C.size_t(count),
		(**C.char)(keyPointerData),
		(*C.size_t)(keySizeData),
		(**C.char)(valuePointerData),
		(*C.size_t)(valueSizeData),
		(**C.char)(errPointerData),
	)
	out := make([][]byte, count)
	for i := range keys {
		err := C.rb_get_char_ptr((**C.char)(errPointerData), C.size_t(i))
		if err != nil {
			msg := C.GoString(err)
			C.rocksdb_free(unsafe.Pointer(err))
			return nil, errors.New(msg)
		}
		value := C.rb_get_char_ptr((**C.char)(valuePointerData), C.size_t(i))
		if value != nil {
			size := C.rb_get_size_t((*C.size_t)(valueSizeData), C.size_t(i))
			out[i] = C.GoBytes(unsafe.Pointer(value), C.int(size))
			C.rocksdb_free(unsafe.Pointer(value))
		}
	}
	return out, nil
}

func (s *Store) putBytes(key []byte, value []byte) error {
	var ckey *C.char
	if len(key) > 0 {
		ckey = (*C.char)(unsafe.Pointer(&key[0]))
	}
	var cvalue *C.char
	if len(value) > 0 {
		cvalue = (*C.char)(unsafe.Pointer(&value[0]))
	}
	var cerr *C.char
	C.rocksdb_put(s.db, s.wo, ckey, C.size_t(len(key)), cvalue, C.size_t(len(value)), &cerr)
	if cerr != nil {
		defer C.rocksdb_free(unsafe.Pointer(cerr))
		return errors.New(C.GoString(cerr))
	}
	return nil
}

func (s *Store) getBytes(key []byte) ([]byte, error) {
	var ckey *C.char
	if len(key) > 0 {
		ckey = (*C.char)(unsafe.Pointer(&key[0]))
	}
	var length C.size_t
	var cerr *C.char
	data := C.rocksdb_get(s.db, s.ro, ckey, C.size_t(len(key)), &length, &cerr)
	if cerr != nil {
		defer C.rocksdb_free(unsafe.Pointer(cerr))
		return nil, errors.New(C.GoString(cerr))
	}
	if data == nil {
		return nil, nil
	}
	defer C.rocksdb_free(unsafe.Pointer(data))
	return C.GoBytes(unsafe.Pointer(data), C.int(length)), nil
}

func (s *Store) normalizeMetadata(meta Metadata) Metadata {
	if meta.StorageCodecVersion == 0 {
		meta.StorageCodecVersion = codecVersion
	}
	if meta.RocksDBTuning == "" {
		meta.RocksDBTuning = s.TuningSummary()
	}
	meta.RocksDBWALDisabled = s.walDisabled
	return meta
}

func (s *Store) TuningSummary() string {
	return fmt.Sprintf("block_cache=%dMiB,bloom=10,write_buffer=64MiB,max_write_buffers=4,max_background_jobs=4", rocksDBBlockCacheMB())
}

func (s *Store) WALDisabled() bool {
	return s.walDisabled
}

func (s *Store) FailNextCommitForTest() {
	s.failCommit = true
}

func (u UTXO) ScriptBytes() ([]byte, error) {
	if u.ScriptPubKeyBytes != nil {
		return u.ScriptPubKeyBytes, nil
	}
	return hex.DecodeString(u.ScriptPubKey)
}

func (u UTXO) ScriptHex() string {
	if u.ScriptPubKey != "" {
		return u.ScriptPubKey
	}
	return hex.EncodeToString(u.ScriptPubKeyBytes)
}

func (u UTXO) DisplayTxID() string {
	if u.TxID != "" {
		return u.TxID
	}
	return displayHash(u.txidInternal[:])
}

func (u UTXO) OutPoint() OutPoint {
	if u.txidInternal != ([32]byte{}) {
		return OutPoint{Vout: u.Vout, hash: u.txidInternal}
	}
	return NewOutPointFromDisplay(u.TxID, u.Vout)
}

func (u UTXO) MarshalJSON() ([]byte, error) {
	type jsonUTXO struct {
		TxID         string `json:"txid"`
		Vout         uint32 `json:"vout"`
		Value        int64  `json:"value"`
		ScriptPubKey string `json:"script_pubkey"`
		Height       int    `json:"height"`
		Coinbase     bool   `json:"coinbase"`
	}
	return json.Marshal(jsonUTXO{
		TxID:         u.DisplayTxID(),
		Vout:         u.Vout,
		Value:        u.Value,
		ScriptPubKey: u.ScriptHex(),
		Height:       u.Height,
		Coinbase:     u.Coinbase,
	})
}

func encodeUTXO(utxo UTXO) ([]byte, error) {
	script, err := utxo.ScriptBytes()
	if err != nil {
		return nil, err
	}
	out := make([]byte, 0, 1+8+4+1+len(script)+5)
	out = append(out, byte(codecVersion))
	tmp := make([]byte, 8)
	binary.LittleEndian.PutUint64(tmp, uint64(utxo.Value))
	out = append(out, tmp...)
	tmp = tmp[:4]
	binary.LittleEndian.PutUint32(tmp, uint32(utxo.Height))
	out = append(out, tmp...)
	if utxo.Coinbase {
		out = append(out, 1)
	} else {
		out = append(out, 0)
	}
	out = append(out, compactSize(uint64(len(script)))...)
	out = append(out, script...)
	return out, nil
}

func decodeUTXO(txid string, vout uint32, value []byte) (UTXO, error) {
	return decodeUTXOForOutPoint(NewOutPointFromDisplay(txid, vout), value)
}

func decodeUTXOForOutPoint(outpoint OutPoint, value []byte) (UTXO, error) {
	if len(value) > 0 && value[0] == byte(codecVersion) {
		if len(value) < 14 {
			return UTXO{}, errors.New("truncated binary UTXO")
		}
		offset := 1
		amount := int64(binary.LittleEndian.Uint64(value[offset : offset+8]))
		offset += 8
		height := int(binary.LittleEndian.Uint32(value[offset : offset+4]))
		offset += 4
		coinbase := value[offset] != 0
		offset++
		scriptLen, next, err := readCompactSize(value, offset)
		if err != nil {
			return UTXO{}, err
		}
		offset = next
		if offset+int(scriptLen) > len(value) {
			return UTXO{}, errors.New("truncated binary UTXO script")
		}
		script := append([]byte{}, value[offset:offset+int(scriptLen)]...)
		return UTXO{TxID: outpoint.TxID, Vout: outpoint.Vout, Value: amount, ScriptPubKeyBytes: script, Height: height, Coinbase: coinbase, txidInternal: outpoint.hash}, nil
	}
	var utxo UTXO
	if err := json.Unmarshal(value, &utxo); err != nil {
		return UTXO{}, err
	}
	if utxo.ScriptPubKeyBytes == nil && utxo.ScriptPubKey != "" {
		script, err := hex.DecodeString(utxo.ScriptPubKey)
		if err == nil {
			utxo.ScriptPubKeyBytes = script
		}
	}
	if utxo.TxID == "" {
		utxo.TxID = outpoint.DisplayTxID()
	}
	utxo.Vout = outpoint.Vout
	utxo.txidInternal = outpoint.hash
	return utxo, nil
}

func compactSize(value uint64) []byte {
	if value < 0xfd {
		return []byte{byte(value)}
	}
	if value <= 0xffff {
		return []byte{0xfd, byte(value), byte(value >> 8)}
	}
	if value <= 0xffffffff {
		out := []byte{0xfe, 0, 0, 0, 0}
		binary.LittleEndian.PutUint32(out[1:], uint32(value))
		return out
	}
	out := []byte{0xff, 0, 0, 0, 0, 0, 0, 0, 0}
	binary.LittleEndian.PutUint64(out[1:], value)
	return out
}

func readCompactSize(data []byte, offset int) (uint64, int, error) {
	if offset >= len(data) {
		return 0, 0, errors.New("truncated compactsize")
	}
	first := data[offset]
	offset++
	switch first {
	case 0xfd:
		if offset+2 > len(data) {
			return 0, 0, errors.New("truncated compactsize16")
		}
		return uint64(binary.LittleEndian.Uint16(data[offset:])), offset + 2, nil
	case 0xfe:
		if offset+4 > len(data) {
			return 0, 0, errors.New("truncated compactsize32")
		}
		return uint64(binary.LittleEndian.Uint32(data[offset:])), offset + 4, nil
	case 0xff:
		if offset+8 > len(data) {
			return 0, 0, errors.New("truncated compactsize64")
		}
		return binary.LittleEndian.Uint64(data[offset:]), offset + 8, nil
	default:
		return uint64(first), offset, nil
	}
}

func (s *Store) deleteLegacyUTXO(txid string, vout uint32) error {
	return s.delete(legacyUTXOKey(txid, vout))
}

func (s *Store) get(key string) ([]byte, error) {
	ckey := C.CString(key)
	defer C.free(unsafe.Pointer(ckey))
	var length C.size_t
	var cerr *C.char
	data := C.rocksdb_get(s.db, s.ro, ckey, C.size_t(len(key)), &length, &cerr)
	if cerr != nil {
		defer C.rocksdb_free(unsafe.Pointer(cerr))
		return nil, errors.New(C.GoString(cerr))
	}
	if data == nil {
		return nil, nil
	}
	defer C.rocksdb_free(unsafe.Pointer(data))
	return C.GoBytes(unsafe.Pointer(data), C.int(length)), nil
}

func (s *Store) datadir() string {
	return s.dataDir
}

func legacyUTXOKey(txid string, vout uint32) string {
	return "utxo:" + txid + ":" + strconv.FormatUint(uint64(vout), 10)
}

func utxoKeyBytes(txid string, vout uint32) []byte {
	raw, err := internalHash(txid)
	if err != nil {
		return []byte(legacyUTXOKey(txid, vout))
	}
	key := make([]byte, 37)
	key[0] = binaryUTXOPrefix[0]
	copy(key[1:33], raw)
	binary.LittleEndian.PutUint32(key[33:37], vout)
	return key
}

func internalHash(display string) ([]byte, error) {
	decoded, err := hex.DecodeString(display)
	if err != nil {
		return nil, err
	}
	if len(decoded) != 32 {
		return nil, fmt.Errorf("txid has %d bytes, want 32", len(decoded))
	}
	for i, j := 0, len(decoded)-1; i < j; i, j = i+1, j-1 {
		decoded[i], decoded[j] = decoded[j], decoded[i]
	}
	return decoded, nil
}

func displayHash(raw []byte) string {
	rev := append([]byte{}, raw...)
	for i, j := 0, len(rev)-1; i < j; i, j = i+1, j-1 {
		rev[i], rev[j] = rev[j], rev[i]
	}
	return hex.EncodeToString(rev)
}

func padHeight(height int) string {
	return leftPad(strconv.Itoa(height), 8)
}

func leftPad(value string, width int) string {
	for len(value) < width {
		value = "0" + value
	}
	return value
}

func SeedTwoBlockProof(datadir string) (Metadata, error) {
	store, err := Open(datadir)
	if err != nil {
		return Metadata{}, err
	}
	defer store.Close()
	meta := Metadata{
		NodeID:              "gobitnode-native-storage",
		GenerationID:        "go-proof-generation",
		Chain:               "testnet4",
		SyncStatus:          "blocks_current",
		ChainstateStatus:    "usable",
		ChainstateBackend:   "rocksdb",
		ValidatedHeight:     2,
		ValidatedHash:       "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253",
		HeaderHeight:        2,
		HeaderHash:          "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253",
		StoredBlockHeight:   2,
		StoredBlockHash:     "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253",
		ChainstateUTXOCount: 1,
	}
	if err := store.PutMetadata(meta); err != nil {
		return Metadata{}, err
	}
	if err := store.put("block:1", []byte("0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28")); err != nil {
		return Metadata{}, err
	}
	if err := store.put("block:2", []byte(meta.ValidatedHash)); err != nil {
		return Metadata{}, err
	}
	if err := store.PutUTXO(UTXO{
		TxID:              "0200000000000000000000000000000000000000000000000000000000000000",
		Vout:              0,
		Value:             4999990000,
		ScriptPubKeyBytes: []byte{0x51},
		Height:            2,
		Coinbase:          true,
	}); err != nil {
		return Metadata{}, err
	}
	return meta, nil
}

func ReadMetadata(datadir string) (Metadata, error) {
	store, err := Open(datadir)
	if err != nil {
		return Metadata{}, err
	}
	defer store.Close()
	return store.Metadata()
}

func rocksDBBlockCacheMB() int {
	value := 256
	if raw := os.Getenv("GOBITNODE_ROCKSDB_BLOCK_CACHE_MB"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			value = parsed
		}
	}
	if value > 8192 {
		return 8192
	}
	return value
}
