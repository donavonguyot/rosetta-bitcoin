package tx

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
)

type OutPoint struct {
	Hash  []byte
	Index uint32
}

type TxIn struct {
	PreviousOutput OutPoint
	ScriptSig      []byte
	Sequence       uint32
}

type TxOut struct {
	Value        int64
	ScriptPubKey []byte
}

type Transaction struct {
	Version  int32
	Inputs   []TxIn
	Outputs  []TxOut
	LockTime uint32
	Witness  [][][]byte
}

func (t Transaction) IsCoinbase() bool {
	if len(t.Inputs) != 1 {
		return false
	}
	in := t.Inputs[0]
	return in.PreviousOutput.Index == 0xffffffff && bytes.Equal(in.PreviousOutput.Hash, make([]byte, 32))
}

func (t Transaction) TxID() string {
	return DisplayHash(DoubleSHA(Serialize(t, false)))
}

func Deserialize(data []byte, offset int) (Transaction, int, error) {
	if offset+4 > len(data) {
		return Transaction{}, 0, errors.New("truncated tx version")
	}
	start := offset
	version := int32(binary.LittleEndian.Uint32(data[offset : offset+4]))
	offset += 4
	witness := false
	if offset+2 <= len(data) && data[offset] == 0x00 && data[offset+1] == 0x01 {
		witness = true
		offset += 2
	}
	inputCount, next, err := ReadCompactSize(data, offset)
	if err != nil {
		return Transaction{}, 0, err
	}
	offset = next
	inputs := make([]TxIn, 0, inputCount)
	for i := uint64(0); i < inputCount; i++ {
		if offset+36 > len(data) {
			return Transaction{}, 0, errors.New("truncated tx input outpoint")
		}
		hash := append([]byte{}, data[offset:offset+32]...)
		offset += 32
		index := binary.LittleEndian.Uint32(data[offset : offset+4])
		offset += 4
		scriptLen, n, err := ReadCompactSize(data, offset)
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
		inputs = append(inputs, TxIn{PreviousOutput: OutPoint{Hash: hash, Index: index}, ScriptSig: scriptSig, Sequence: sequence})
	}
	outputCount, next, err := ReadCompactSize(data, offset)
	if err != nil {
		return Transaction{}, 0, err
	}
	offset = next
	outputs := make([]TxOut, 0, outputCount)
	for i := uint64(0); i < outputCount; i++ {
		if offset+8 > len(data) {
			return Transaction{}, 0, errors.New("truncated tx output value")
		}
		value := int64(binary.LittleEndian.Uint64(data[offset : offset+8]))
		offset += 8
		scriptLen, n, err := ReadCompactSize(data, offset)
		if err != nil {
			return Transaction{}, 0, err
		}
		offset = n
		if offset+int(scriptLen) > len(data) {
			return Transaction{}, 0, errors.New("truncated tx output script")
		}
		spk := append([]byte{}, data[offset:offset+int(scriptLen)]...)
		offset += int(scriptLen)
		outputs = append(outputs, TxOut{Value: value, ScriptPubKey: spk})
	}
	witnesses := [][][]byte{}
	if witness {
		for i := uint64(0); i < inputCount; i++ {
			itemCount, n, err := ReadCompactSize(data, offset)
			if err != nil {
				return Transaction{}, 0, err
			}
			offset = n
			stack := make([][]byte, 0, itemCount)
			for j := uint64(0); j < itemCount; j++ {
				itemLen, n, err := ReadCompactSize(data, offset)
				if err != nil {
					return Transaction{}, 0, err
				}
				offset = n
				if offset+int(itemLen) > len(data) {
					return Transaction{}, 0, errors.New("truncated witness item")
				}
				stack = append(stack, append([]byte{}, data[offset:offset+int(itemLen)]...))
				offset += int(itemLen)
			}
			witnesses = append(witnesses, stack)
		}
	}
	if offset+4 > len(data) {
		return Transaction{}, 0, errors.New("truncated tx locktime")
	}
	lockTime := binary.LittleEndian.Uint32(data[offset : offset+4])
	offset += 4
	if offset < start {
		return Transaction{}, 0, errors.New("transaction parser underflow")
	}
	return Transaction{Version: version, Inputs: inputs, Outputs: outputs, LockTime: lockTime, Witness: witnesses}, offset, nil
}

func Serialize(t Transaction, includeWitness bool) []byte {
	var out []byte
	out = append(out, PackInt32(uint32(t.Version))...)
	useWitness := includeWitness && len(t.Witness) > 0
	if useWitness {
		out = append(out, 0x00, 0x01)
	}
	out = append(out, CompactSize(uint64(len(t.Inputs)))...)
	for _, in := range t.Inputs {
		out = append(out, in.PreviousOutput.Hash...)
		out = append(out, PackInt32(in.PreviousOutput.Index)...)
		out = append(out, CompactSize(uint64(len(in.ScriptSig)))...)
		out = append(out, in.ScriptSig...)
		out = append(out, PackInt32(in.Sequence)...)
	}
	out = append(out, CompactSize(uint64(len(t.Outputs)))...)
	for _, txout := range t.Outputs {
		out = append(out, PackInt64(uint64(txout.Value))...)
		out = append(out, CompactSize(uint64(len(txout.ScriptPubKey)))...)
		out = append(out, txout.ScriptPubKey...)
	}
	if useWitness {
		for _, stack := range t.Witness {
			out = append(out, CompactSize(uint64(len(stack)))...)
			for _, item := range stack {
				out = append(out, CompactSize(uint64(len(item)))...)
				out = append(out, item...)
			}
		}
	}
	out = append(out, PackInt32(t.LockTime)...)
	return out
}

func SerializeTxOut(output TxOut) []byte {
	var out []byte
	out = append(out, PackInt64(uint64(output.Value))...)
	out = append(out, CompactSize(uint64(len(output.ScriptPubKey)))...)
	out = append(out, output.ScriptPubKey...)
	return out
}

func SerializeOutPoint(outpoint OutPoint) []byte {
	out := append([]byte{}, outpoint.Hash...)
	out = append(out, PackInt32(outpoint.Index)...)
	return out
}

func PackInt32(value uint32) []byte {
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, value)
	return out
}

func PackInt64(value uint64) []byte {
	out := make([]byte, 8)
	binary.LittleEndian.PutUint64(out, value)
	return out
}

func CompactSize(value uint64) []byte {
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

func ReadCompactSize(data []byte, offset int) (uint64, int, error) {
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

func DoubleSHA(data []byte) []byte {
	first := sha256.Sum256(data)
	second := sha256.Sum256(first[:])
	return second[:]
}

func DisplayHash(raw []byte) string {
	rev := append([]byte{}, raw...)
	for i, j := 0, len(rev)-1; i < j; i, j = i+1, j-1 {
		rev[i], rev[j] = rev[j], rev[i]
	}
	return hex.EncodeToString(rev)
}

func ParseHexTransaction(rawHex string) (Transaction, error) {
	data, err := hex.DecodeString(rawHex)
	if err != nil {
		return Transaction{}, err
	}
	t, consumed, err := Deserialize(data, 0)
	if err != nil {
		return Transaction{}, err
	}
	if consumed != len(data) {
		return Transaction{}, fmt.Errorf("transaction parser consumed %d of %d bytes", consumed, len(data))
	}
	return t, nil
}

func ParseBlockTransactions(raw []byte) ([]Transaction, error) {
	if len(raw) < 81 {
		return nil, errors.New("block too short")
	}
	count, offset, err := ReadCompactSize(raw, 80)
	if err != nil {
		return nil, err
	}
	txs := make([]Transaction, 0, count)
	for i := uint64(0); i < count; i++ {
		transaction, next, err := Deserialize(raw, offset)
		if err != nil {
			return nil, fmt.Errorf("tx %d at offset %d: %w", i, offset, err)
		}
		txs = append(txs, transaction)
		offset = next
	}
	if offset != len(raw) {
		return nil, fmt.Errorf("block parser consumed %d of %d bytes", offset, len(raw))
	}
	return txs, nil
}
