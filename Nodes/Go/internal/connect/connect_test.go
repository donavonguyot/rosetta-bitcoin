package connect

import (
	"os"
	"testing"

	"rosettabitcoin/nodes/go/internal/script"
	"rosettabitcoin/nodes/go/internal/storage"
	txtypes "rosettabitcoin/nodes/go/internal/tx"
)

func TestBlockViewSameBlockSpendLeavesNoExternalMutation(t *testing.T) {
	view := newBlockView(1, 1)
	outpoint := storage.NewOutPointFromDisplay("0100000000000000000000000000000000000000000000000000000000000000", 0)
	utxo := storage.NewUTXO(outpoint, 10, []byte{0x51}, 1, false)
	view.loaded[outpoint] = nil
	view.addCreated([]storage.UTXO{utxo})
	if _, ok := view.find(outpoint); !ok {
		t.Fatal("same-block created output was not visible")
	}
	view.markSpent(outpoint, utxo)
	if _, ok := view.find(outpoint); ok {
		t.Fatal("same-block spent output remained visible")
	}
	if got := view.createdUTXOs(); len(got) != 0 {
		t.Fatalf("same-block spent output remained staged: %#v", got)
	}
	if got := view.externalSpends(); len(got) != 0 {
		t.Fatalf("same-block spend became external delete: %#v", got)
	}
	if got := view.undoEntries(); len(got) != 0 {
		t.Fatalf("same-block spend produced external undo: %#v", got)
	}
}

func TestBlockViewExternalSpendProducesDeleteAndUndo(t *testing.T) {
	view := newBlockView(1, 0)
	outpoint := storage.NewOutPointFromDisplay("0200000000000000000000000000000000000000000000000000000000000000", 1)
	utxo := storage.NewUTXO(outpoint, 20, []byte{0x51}, 1, false)
	view.loaded[outpoint] = &utxo
	view.addSpentScriptType([]byte{0x76, 0xa9, 0x14, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 0x88, 0xac})
	view.markSpent(outpoint, utxo)
	if got := view.externalSpends(); len(got) != 1 || got[0] != outpoint {
		t.Fatalf("external spend not recorded: %#v", got)
	}
	if got := view.undoEntries(); len(got) != 1 || got[0].Outpoint != outpoint {
		t.Fatalf("external undo not recorded: %#v", got)
	}
	if got := view.spentPrevoutScriptTypes["p2pkh"]; got != 1 {
		t.Fatalf("spent script type telemetry missing: %#v", view.spentPrevoutScriptTypes)
	}
}

func TestOutputsForSkipsCoreUnspendableOutputs(t *testing.T) {
	tx := txtypes.Transaction{
		Outputs: []txtypes.TxOut{
			{Value: 1, ScriptPubKey: nil},
			{Value: 2, ScriptPubKey: []byte{0x6a, 0x01, 0x02}},
			{Value: 3, ScriptPubKey: []byte{0x51}},
		},
	}

	txidInternal := txtypes.DoubleSHA(txtypes.Serialize(tx, false))
	utxos := outputsFor(10, &tx, txidInternal, false)
	if len(utxos) != 1 {
		t.Fatalf("expected one spendable output, got %#v", utxos)
	}
	if utxos[0].Value != 3 || utxos[0].Vout != 2 {
		t.Fatalf("wrong output retained: %#v", utxos[0])
	}
}

func TestScriptRunnerDeterministicFirstFailure(t *testing.T) {
	t.Setenv("GOBITNODE_PAR_SCRIPT_VERIFY", "1")
	t.Setenv("GOBITNODE_PAR_SCRIPT_THREADS", "4")
	runner := newScriptRunner()
	defer runner.close()
	firstTx := txtypes.Transaction{}
	secondTx := txtypes.Transaction{}
	firstOptions := script.VerifyInputOptions{}
	secondOptions := script.VerifyInputOptions{}
	firstUTXO := storage.UTXO{ScriptPubKeyBytes: []byte{0x51}}
	secondUTXO := storage.UTXO{ScriptPubKeyBytes: []byte{0x51}}
	jobs := []scriptJob{
		{
			txid:       "first",
			inputIndex: 0,
			tx:         &firstTx,
			utxo:       &firstUTXO,
			options:    &firstOptions,
		},
		{
			txid:       "second",
			inputIndex: 0,
			tx:         &secondTx,
			utxo:       &secondUTXO,
			options:    &secondOptions,
		},
	}
	failure, stats := runner.verify(jobs)
	if failure == nil {
		t.Fatal("expected failure")
	}
	if stats.workerTime <= 0 || stats.batches != 1 {
		t.Fatal("expected worker verification timing")
	}
	if failure.job.txid != "first" {
		t.Fatalf("parallel runner returned nondeterministic failure: %s", failure.job.txid)
	}
	os.Unsetenv("GOBITNODE_PAR_SCRIPT_VERIFY")
}
