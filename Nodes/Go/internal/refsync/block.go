package refsync

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
)

type BlockInfo struct {
	Hash       string
	PrevHash   string
	MerkleRoot string
	TxCount    int
	Raw        []byte
}

type Transaction struct {
	TxID     string
	Inputs   []TxInput
	Outputs  []TxOutput
	Coinbase bool
	txidRaw  []byte
}

type TxInput struct {
	PrevTxID  string
	PrevVout  uint32
	ScriptSig []byte
	Sequence  uint32
}

type TxOutput struct {
	Value        int64
	ScriptPubKey []byte
}

func ValidateBlock(raw []byte, expectedHash, expectedPrev string) (BlockInfo, error) {
	info, _, err := DecodeBlock(raw, expectedHash, expectedPrev)
	return info, err
}

func DecodeBlock(raw []byte, expectedHash, expectedPrev string) (BlockInfo, []Transaction, error) {
	if len(raw) < 81 {
		return BlockInfo{}, nil, errors.New("block too short")
	}
	header := raw[:80]
	hashBytes := doubleSHA(header)
	hash := displayHash(hashBytes)
	if expectedHash != "" && hash != expectedHash {
		return BlockInfo{}, nil, fmt.Errorf("block hash mismatch: got %s want %s", hash, expectedHash)
	}
	if !checkPoW(hashBytes, binary.LittleEndian.Uint32(header[72:76])) {
		return BlockInfo{}, nil, fmt.Errorf("proof of work target not satisfied at %s", hash)
	}
	prev := displayHash(header[4:36])
	if expectedPrev != "" && prev != expectedPrev {
		return BlockInfo{}, nil, fmt.Errorf("prev hash mismatch: got %s want %s", prev, expectedPrev)
	}
	txs, consumed, err := parseTransactions(raw[80:])
	if err != nil {
		return BlockInfo{}, nil, err
	}
	if consumed != len(raw)-80 {
		return BlockInfo{}, nil, fmt.Errorf("block parser consumed %d of %d payload bytes", consumed, len(raw)-80)
	}
	txids := make([][]byte, 0, len(txs))
	for _, tx := range txs {
		txids = append(txids, tx.txidRaw)
	}
	merkle := merkleRoot(txids)
	if !bytes.Equal(merkle, header[36:68]) {
		return BlockInfo{}, nil, fmt.Errorf("merkle root mismatch at %s", hash)
	}
	return BlockInfo{
		Hash:       hash,
		PrevHash:   prev,
		MerkleRoot: displayHash(merkle),
		TxCount:    len(txids),
		Raw:        raw,
	}, txs, nil
}

func parseTransactions(payload []byte) ([]Transaction, int, error) {
	count, offset, err := readVarInt(payload, 0)
	if err != nil {
		return nil, 0, err
	}
	txs := make([]Transaction, 0, count)
	for i := uint64(0); i < count; i++ {
		start := offset
		tx, next, err := parseTransaction(payload, offset)
		if err != nil {
			return nil, 0, fmt.Errorf("tx %d at offset %d: %w", i, start, err)
		}
		txs = append(txs, tx)
		offset = next
	}
	return txs, offset, nil
}

func parseTransaction(data []byte, offset int) (Transaction, int, error) {
	start := offset
	if offset+4 > len(data) {
		return Transaction{}, 0, errors.New("truncated tx version")
	}
	version := data[offset : offset+4]
	offset += 4
	segwit := false
	if offset+2 <= len(data) && data[offset] == 0x00 && data[offset+1] != 0x00 {
		segwit = true
		offset += 2
	}
	vinStart := offset
	inCount, next, err := readVarInt(data, offset)
	if err != nil {
		return Transaction{}, 0, err
	}
	offset = next
	inputs := make([]TxInput, 0, inCount)
	for i := uint64(0); i < inCount; i++ {
		if offset+36 > len(data) {
			return Transaction{}, 0, errors.New("truncated tx input outpoint")
		}
		prevHash := append([]byte{}, data[offset:offset+32]...)
		prevVout := binary.LittleEndian.Uint32(data[offset+32 : offset+36])
		offset += 36
		scriptLen, n, err := readVarInt(data, offset)
		if err != nil {
			return Transaction{}, 0, err
		}
		offset = n
		if offset+int(scriptLen) > len(data) {
			return Transaction{}, 0, errors.New("truncated tx input script")
		}
		scriptSig := append([]byte{}, data[offset:offset+int(scriptLen)]...)
		offset += int(scriptLen)
		if offset+4 > len(data) {
			return Transaction{}, 0, errors.New("truncated tx input sequence")
		}
		sequence := binary.LittleEndian.Uint32(data[offset : offset+4])
		offset += 4
		inputs = append(inputs, TxInput{
			PrevTxID:  displayHash(prevHash),
			PrevVout:  prevVout,
			ScriptSig: scriptSig,
			Sequence:  sequence,
		})
	}
	vinEnd := offset
	voutStart := offset
	outCount, next, err := readVarInt(data, offset)
	if err != nil {
		return Transaction{}, 0, err
	}
	offset = next
	outputs := make([]TxOutput, 0, outCount)
	for i := uint64(0); i < outCount; i++ {
		if offset+8 > len(data) {
			return Transaction{}, 0, errors.New("truncated tx output value")
		}
		value := int64(binary.LittleEndian.Uint64(data[offset : offset+8]))
		offset += 8
		scriptLen, n, err := readVarInt(data, offset)
		if err != nil {
			return Transaction{}, 0, err
		}
		offset = n
		if offset+int(scriptLen) > len(data) {
			return Transaction{}, 0, errors.New("truncated tx output script")
		}
		scriptPubKey := append([]byte{}, data[offset:offset+int(scriptLen)]...)
		offset += int(scriptLen)
		if offset > len(data) {
			return Transaction{}, 0, errors.New("truncated tx output script")
		}
		outputs = append(outputs, TxOutput{Value: value, ScriptPubKey: scriptPubKey})
	}
	voutEnd := offset
	if segwit {
		for i := uint64(0); i < inCount; i++ {
			items, n, err := readVarInt(data, offset)
			if err != nil {
				return Transaction{}, 0, err
			}
			offset = n
			for j := uint64(0); j < items; j++ {
				itemLen, n, err := readVarInt(data, offset)
				if err != nil {
					return Transaction{}, 0, err
				}
				offset = n + int(itemLen)
				if offset > len(data) {
					return Transaction{}, 0, errors.New("truncated witness item")
				}
			}
		}
	}
	if offset+4 > len(data) {
		return Transaction{}, 0, errors.New("truncated tx locktime")
	}
	locktime := data[offset : offset+4]
	offset += 4
	var noWitness []byte
	if segwit {
		noWitness = append(noWitness, version...)
		noWitness = append(noWitness, data[vinStart:vinEnd]...)
		noWitness = append(noWitness, data[voutStart:voutEnd]...)
		noWitness = append(noWitness, locktime...)
	} else {
		noWitness = data[start:offset]
	}
	txid := doubleSHA(noWitness)
	return Transaction{
		TxID:     displayHash(txid),
		Inputs:   inputs,
		Outputs:  outputs,
		Coinbase: isCoinbase(inputs),
		txidRaw:  txid,
	}, offset, nil
}

func isCoinbase(inputs []TxInput) bool {
	if len(inputs) != 1 {
		return false
	}
	if inputs[0].PrevVout != 0xffffffff {
		return false
	}
	return inputs[0].PrevTxID == "0000000000000000000000000000000000000000000000000000000000000000"
}

func readVarInt(data []byte, offset int) (uint64, int, error) {
	if offset >= len(data) {
		return 0, 0, errors.New("truncated varint")
	}
	prefix := data[offset]
	offset++
	switch prefix {
	case 0xfd:
		if offset+2 > len(data) {
			return 0, 0, errors.New("truncated varint16")
		}
		return uint64(binary.LittleEndian.Uint16(data[offset:])), offset + 2, nil
	case 0xfe:
		if offset+4 > len(data) {
			return 0, 0, errors.New("truncated varint32")
		}
		return uint64(binary.LittleEndian.Uint32(data[offset:])), offset + 4, nil
	case 0xff:
		if offset+8 > len(data) {
			return 0, 0, errors.New("truncated varint64")
		}
		return binary.LittleEndian.Uint64(data[offset:]), offset + 8, nil
	default:
		return uint64(prefix), offset, nil
	}
}

func merkleRoot(txids [][]byte) []byte {
	if len(txids) == 0 {
		return make([]byte, 32)
	}
	level := txids
	for len(level) > 1 {
		next := make([][]byte, 0, (len(level)+1)/2)
		for i := 0; i < len(level); i += 2 {
			left := level[i]
			right := left
			if i+1 < len(level) {
				right = level[i+1]
			}
			next = append(next, doubleSHA(append(append([]byte{}, left...), right...)))
		}
		level = next
	}
	return level[0]
}

func doubleSHA(data []byte) []byte {
	first := sha256.Sum256(data)
	second := sha256.Sum256(first[:])
	return second[:]
}

func displayHash(raw []byte) string {
	rev := append([]byte{}, raw...)
	for i, j := 0, len(rev)-1; i < j; i, j = i+1, j-1 {
		rev[i], rev[j] = rev[j], rev[i]
	}
	return hex.EncodeToString(rev)
}

func checkPoW(hash []byte, bits uint32) bool {
	target := compactToBig(bits)
	if target.Sign() <= 0 {
		return false
	}
	rev := append([]byte{}, hash...)
	for i, j := 0, len(rev)-1; i < j; i, j = i+1, j-1 {
		rev[i], rev[j] = rev[j], rev[i]
	}
	value := new(big.Int).SetBytes(rev)
	return value.Cmp(target) <= 0
}

func compactToBig(bits uint32) *big.Int {
	size := byte(bits >> 24)
	word := bits & 0x007fffff
	result := new(big.Int).SetUint64(uint64(word))
	if size <= 3 {
		result.Rsh(result, 8*uint(3-size))
	} else {
		result.Lsh(result, 8*uint(size-3))
	}
	if bits&0x00800000 != 0 {
		result.Neg(result)
	}
	return result
}
