package connect

import (
	"encoding/binary"
	"testing"

	"rosettabitcoin/nodes/go/internal/storage"
)

func BenchmarkUTXOApplyHeight20888Shape(b *testing.B) {
	benchmarkUTXOApplyShape(b, 6760, 3)
}

func BenchmarkUTXOApplyGiantWitness51540Shape(b *testing.B) {
	benchmarkUTXOApplyShape(b, 14200, 12)
}

func BenchmarkUTXOApplyGiantWitness52341Shape(b *testing.B) {
	benchmarkUTXOApplyShape(b, 14556, 62)
}

func benchmarkUTXOApplyShape(b *testing.B, spends int, creates int) {
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		view := newBlockView(spends, creates)
		for n := 0; n < spends; n++ {
			outpoint := diagnosticOutPoint(n, 0)
			utxo := storage.NewUTXO(outpoint, int64(n+1), []byte{0x51}, 1, false)
			view.loaded[outpoint] = &utxo
			view.markSpent(outpoint, utxo)
		}
		view.addCreated(diagnosticCreatedUTXOs(spends, creates))
		if got := len(view.externalSpends()); got != spends {
			b.Fatalf("external spend count mismatch: got %d want %d", got, spends)
		}
		if got := len(view.undoEntries()); got != spends {
			b.Fatalf("undo count mismatch: got %d want %d", got, spends)
		}
		if got := len(view.createdUTXOs()); got != creates {
			b.Fatalf("created count mismatch: got %d want %d", got, creates)
		}
	}
}

func diagnosticCreatedUTXOs(offset int, count int) []storage.UTXO {
	utxos := make([]storage.UTXO, 0, count)
	for n := 0; n < count; n++ {
		outpoint := diagnosticOutPoint(offset+n, uint32(n))
		utxos = append(utxos, storage.NewUTXO(outpoint, int64(n+1), []byte{0x51}, 2, false))
	}
	return utxos
}

func diagnosticOutPoint(index int, vout uint32) storage.OutPoint {
	var hash [32]byte
	binary.LittleEndian.PutUint64(hash[:8], uint64(index+1))
	binary.LittleEndian.PutUint64(hash[8:16], uint64(index+1)*0x9e3779b185ebca87)
	return storage.NewOutPointFromInternal(hash[:], vout)
}
