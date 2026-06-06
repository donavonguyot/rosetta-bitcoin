package script

import (
	"bytes"
	"testing"

	"rosettabitcoin/nodes/go/internal/tx"
)

func TestBIP143SighashCacheMatchesUncached(t *testing.T) {
	transaction := cacheTestTransaction()
	prevouts := cacheTestPrevouts()
	cache := newSighashCache(transaction, prevouts)
	precomputed := newSighashCacheFromPrecompute(transaction, prevouts, NewSighashPrecompute(transaction, prevouts))
	scriptCode := []byte{OP_DUP, OP_HASH160, 20, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, OP_EQUALVERIFY, OP_CHECKSIG}
	for _, hashType := range []int{1, 2, 3, 0x81, 0x82, 0x83} {
		got := bip143SighashCached(cache, transaction, 1, scriptCode, prevouts[1].Amount, hashType)
		want := bip143Sighash(transaction, 1, scriptCode, prevouts[1].Amount, hashType)
		if !bytes.Equal(got, want) {
			t.Fatalf("BIP143 hash type %#x mismatch: got %x want %x", hashType, got, want)
		}
		gotPrecomputed := bip143SighashCached(precomputed, transaction, 1, scriptCode, prevouts[1].Amount, hashType)
		if !bytes.Equal(gotPrecomputed, want) {
			t.Fatalf("precomputed BIP143 hash type %#x mismatch: got %x want %x", hashType, gotPrecomputed, want)
		}
	}
}

func TestTaprootSighashCacheMatchesUncached(t *testing.T) {
	transaction := cacheTestTransaction()
	prevouts := cacheTestPrevouts()
	cache := newSighashCache(transaction, prevouts)
	precomputed := newSighashCacheFromPrecompute(transaction, prevouts, NewSighashPrecompute(transaction, prevouts))
	for _, opt := range []taprootOptions{
		{hashType: taprootSighashDefault, codeSeparatorPos: 0xffffffff},
		{hashType: taprootSighashAll, codeSeparatorPos: 0xffffffff},
		{hashType: taprootSighashNone, codeSeparatorPos: 0xffffffff},
		{hashType: taprootSighashSingle, codeSeparatorPos: 0xffffffff},
		{hashType: 0x81, codeSeparatorPos: 0xffffffff},
		{hashType: 0x82, codeSeparatorPos: 0xffffffff},
		{hashType: 0x83, codeSeparatorPos: 0xffffffff},
		{hashType: taprootSighashAll, annex: []byte{0x50, 0x01}, extFlag: 1, tapleafHash: bytes.Repeat([]byte{0x11}, 32), codeSeparatorPos: 7},
	} {
		got, err := taprootSighashCached(cache, transaction, 1, prevouts, opt)
		if err != nil {
			t.Fatalf("cached taproot hash type %#x: %v", opt.hashType, err)
		}
		want, err := taprootSighash(transaction, 1, prevouts, opt)
		if err != nil {
			t.Fatalf("uncached taproot hash type %#x: %v", opt.hashType, err)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("Taproot hash type %#x mismatch: got %x want %x", opt.hashType, got, want)
		}
		gotPrecomputed, err := taprootSighashCached(precomputed, transaction, 1, prevouts, opt)
		if err != nil {
			t.Fatalf("precomputed taproot hash type %#x: %v", opt.hashType, err)
		}
		if !bytes.Equal(gotPrecomputed, want) {
			t.Fatalf("precomputed Taproot hash type %#x mismatch: got %x want %x", opt.hashType, gotPrecomputed, want)
		}
	}
}

func cacheTestTransaction() tx.Transaction {
	return tx.Transaction{
		Version: 2,
		Inputs: []tx.TxIn{
			{PreviousOutput: tx.OutPoint{Hash: bytes.Repeat([]byte{0x01}, 32), Index: 0}, ScriptSig: []byte{0x51}, Sequence: 0xfffffffd},
			{PreviousOutput: tx.OutPoint{Hash: bytes.Repeat([]byte{0x02}, 32), Index: 1}, ScriptSig: []byte{0x52}, Sequence: 0xfffffffc},
		},
		Outputs: []tx.TxOut{
			{Value: 1000, ScriptPubKey: []byte{OP_1}},
			{Value: 2000, ScriptPubKey: []byte{0x52}},
		},
		LockTime: 42,
	}
}

func cacheTestPrevouts() []SpentPrevout {
	return []SpentPrevout{
		{Amount: 3000, ScriptPubKey: []byte{OP_1}},
		{Amount: 4000, ScriptPubKey: []byte{0x52}},
	}
}
