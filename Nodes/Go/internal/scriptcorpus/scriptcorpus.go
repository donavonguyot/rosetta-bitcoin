package scriptcorpus

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"rosettabitcoin/nodes/go/internal/crypto"
	"rosettabitcoin/nodes/go/internal/repo"
	"rosettabitcoin/nodes/go/internal/script"
	"rosettabitcoin/nodes/go/internal/surface"
	"rosettabitcoin/nodes/go/internal/tx"
)

type Summary struct {
	FixtureCount int    `json:"fixture_count"`
	Passed       int    `json:"passed"`
	Failed       int    `json:"failed"`
	Result       string `json:"result"`
	ResultPath   string `json:"result_path"`
}

type manifestDocument struct {
	FixtureCount int             `json:"fixture_count"`
	Fixtures     []manifestEntry `json:"fixtures"`
}

type manifestEntry struct {
	FixtureID      string              `json:"fixture_id"`
	Height         int                 `json:"height"`
	TxID           string              `json:"txid"`
	InputIndex     int                 `json:"input_index"`
	ExpectedResult string              `json:"expected_result"`
	MissingRule    string              `json:"missing_rule"`
	RequiredRules  []string            `json:"required_rules"`
	PrevAmountSats *int64              `json:"prev_amount_sats"`
	SpentSPK       string              `json:"spent_script_pubkey"`
	Files          map[string][]string `json:"files"`
}

type prevoutJSON struct {
	Amount        *int64 `json:"amount"`
	AmountSats    *int64 `json:"amount_sats"`
	Value         *int64 `json:"value"`
	SPK           string `json:"spk"`
	ScriptPubKey  string `json:"script_pubkey"`
	ScriptPubKey2 string `json:"scriptPubKey"`
}

type resultRow struct {
	FixtureID     string   `json:"fixture_id"`
	Result        string   `json:"result"`
	Height        int      `json:"height"`
	TxID          string   `json:"txid"`
	InputIndex    int      `json:"input_index"`
	RequiredRules []string `json:"required_rules"`
	MissingRule   string   `json:"missing_rule"`
	Failure       string   `json:"failure"`
	FailureStage  string   `json:"failure_stage"`
	FailureType   string   `json:"failure_type"`
	DurationMS    int64    `json:"duration_ms"`
}

type resultDocument struct {
	Implementation string         `json:"implementation"`
	Category       string         `json:"category"`
	RuntimeSurface string         `json:"runtime_surface"`
	CapturedAt     string         `json:"captured_at"`
	Commit         string         `json:"commit"`
	Manifest       string         `json:"manifest"`
	FixtureCount   int            `json:"fixture_count"`
	Passed         int            `json:"passed"`
	Failed         int            `json:"failed"`
	Result         string         `json:"result"`
	Verifier       map[string]any `json:"verifier"`
	Results        []resultRow    `json:"results"`
}

func DefaultManifest() (string, error) {
	root, err := repo.Root()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "Shared", "conformance", "fixtures", "scripts", "manifest.json"), nil
}

func DefaultResultPath() (string, error) {
	root, err := repo.Root()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "Shared", "conformance", "results", "go_script_corpus_"+time.Now().UTC().Format("2006-01-02")+".json"), nil
}

func Run(manifestPath, resultPath, fixtureID string) (Summary, error) {
	root, rootErr := repo.Root()
	if manifestPath == "" {
		if rootErr != nil {
			return Summary{}, rootErr
		}
		manifestPath = filepath.Join(root, "Shared", "conformance", "fixtures", "scripts", "manifest.json")
	}
	if resultPath == "" {
		if rootErr != nil {
			return Summary{}, rootErr
		}
		resultPath = filepath.Join(root, "Shared", "conformance", "results", "go_script_corpus_"+time.Now().UTC().Format("2006-01-02")+".json")
	}
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return Summary{}, err
	}
	var manifest manifestDocument
	if err := json.Unmarshal(data, &manifest); err != nil {
		return Summary{}, err
	}
	rows := []resultRow{}
	passed := 0
	failed := 0
	verifier := crypto.NewVerifier()
	if verifier == nil {
		return Summary{}, fmt.Errorf("native crypto verifier unavailable")
	}
	defer verifier.Close()
	for _, entry := range manifest.Fixtures {
		if fixtureID != "" && entry.FixtureID != fixtureID {
			continue
		}
		start := time.Now()
		row := runEntry(manifestPath, entry, verifier)
		row.DurationMS = time.Since(start).Milliseconds()
		if row.Result == "passed" {
			passed++
		} else {
			failed++
		}
		rows = append(rows, row)
	}
	result := "passed"
	if failed > 0 {
		result = "failed"
	}
	doc := resultDocument{
		Implementation: "GoNode",
		Category:       "script_corpus",
		RuntimeSurface: surface.RuntimeSurface(),
		CapturedAt:     time.Now().UTC().Format(time.RFC3339),
		Commit:         commit(root),
		Manifest:       manifestName(root, manifestPath),
		FixtureCount:   len(rows),
		Passed:         passed,
		Failed:         failed,
		Result:         result,
		Verifier: map[string]any{
			"engine":         "go_native",
			"crypto_backend": "libsecp256k1/reused_context",
			"context_mode":   verifier.ContextMode(),
			"source":         "Nodes/Go/internal/script",
		},
		Results: rows,
	}
	if err := os.MkdirAll(filepath.Dir(resultPath), 0o755); err != nil {
		return Summary{}, err
	}
	payload, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return Summary{}, err
	}
	if err := os.WriteFile(resultPath, append(payload, '\n'), 0o644); err != nil {
		return Summary{}, err
	}
	return Summary{FixtureCount: len(rows), Passed: passed, Failed: failed, Result: result, ResultPath: resultPath}, nil
}

func runEntry(manifestPath string, entry manifestEntry, verifier *crypto.Verifier) resultRow {
	row := resultRow{
		FixtureID:     entry.FixtureID,
		Result:        "failed",
		Height:        entry.Height,
		TxID:          entry.TxID,
		InputIndex:    entry.InputIndex,
		RequiredRules: entry.RequiredRules,
		MissingRule:   entry.MissingRule,
	}
	err := verifyEntry(manifestPath, entry, verifier)
	if err != nil {
		row.Failure = err.Error()
		row.FailureType = fmt.Sprintf("%T", err)
		row.FailureStage = failureStage(err.Error())
		return row
	}
	row.Result = "passed"
	return row
}

func verifyEntry(manifestPath string, entry manifestEntry, verifier *crypto.Verifier) (err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("panic: %v", recovered)
		}
	}()
	if entry.ExpectedResult != "" && entry.ExpectedResult != "valid" {
		return fmt.Errorf("unsupported expected result: %s", entry.ExpectedResult)
	}
	txPath := firstPath(manifestPath, entry, "tx")
	if txPath == "" {
		return fmt.Errorf("fixture has no transaction file")
	}
	raw, err := readHex(txPath)
	if err != nil {
		return err
	}
	transaction, consumed, err := tx.Deserialize(raw, 0)
	if err != nil {
		return err
	}
	if consumed != len(raw) {
		return fmt.Errorf("transaction parser consumed %d of %d bytes", consumed, len(raw))
	}
	prevouts, err := alignPrevouts(manifestPath, entry, transaction)
	if err != nil {
		return err
	}
	if entry.InputIndex >= len(prevouts) {
		return fmt.Errorf("fixture input_index has no matching prevout")
	}
	target := prevouts[entry.InputIndex]
	return script.VerifyTransactionInput(transaction, entry.InputIndex, script.VerifyInputOptions{
		ScriptPubKey:  target.ScriptPubKey,
		Amount:        target.Amount,
		SpentPrevouts: prevouts,
		Verifier:      verifier,
	})
}

func alignPrevouts(manifestPath string, entry manifestEntry, transaction tx.Transaction) ([]script.SpentPrevout, error) {
	prevouts, err := loadPrevouts(manifestPath, entry)
	if err != nil {
		return nil, err
	}
	if len(prevouts) == len(transaction.Inputs) {
		return prevouts, nil
	}
	target, err := targetPrevout(manifestPath, entry, prevouts)
	if err != nil {
		return nil, err
	}
	for len(prevouts) < len(transaction.Inputs) {
		prevouts = append(prevouts, script.SpentPrevout{})
	}
	prevouts[entry.InputIndex] = target
	return prevouts, nil
}

func loadPrevouts(manifestPath string, entry manifestEntry) ([]script.SpentPrevout, error) {
	prevoutsPath := firstPath(manifestPath, entry, "prevouts")
	if prevoutsPath != "" {
		data, err := os.ReadFile(prevoutsPath)
		if err != nil {
			return nil, err
		}
		var parsed []prevoutJSON
		if err := json.Unmarshal(data, &parsed); err != nil {
			return nil, err
		}
		out := make([]script.SpentPrevout, 0, len(parsed))
		for _, p := range parsed {
			prevout, err := parsePrevout(p)
			if err != nil {
				return nil, err
			}
			out = append(out, prevout)
		}
		return out, nil
	}
	target, err := targetPrevout(manifestPath, entry, nil)
	if err != nil {
		return nil, err
	}
	return []script.SpentPrevout{target}, nil
}

func targetPrevout(manifestPath string, entry manifestEntry, fallback []script.SpentPrevout) (script.SpentPrevout, error) {
	spkPath := firstPath(manifestPath, entry, "prev_spk")
	var scriptHex string
	var err error
	if spkPath != "" {
		data, err := os.ReadFile(spkPath)
		if err != nil {
			return script.SpentPrevout{}, err
		}
		scriptHex = strings.TrimSpace(string(data))
	} else {
		scriptHex = strings.TrimSpace(entry.SpentSPK)
	}
	if entry.PrevAmountSats != nil && scriptHex != "" {
		spk, err := hex.DecodeString(scriptHex)
		if err != nil {
			return script.SpentPrevout{}, err
		}
		return script.SpentPrevout{Amount: *entry.PrevAmountSats, ScriptPubKey: spk}, nil
	}
	if len(fallback) > 0 {
		return fallback[0], nil
	}
	return script.SpentPrevout{}, err
}

func parsePrevout(p prevoutJSON) (script.SpentPrevout, error) {
	var amount *int64
	for _, candidate := range []*int64{p.Amount, p.AmountSats, p.Value} {
		if candidate != nil {
			amount = candidate
			break
		}
	}
	scriptHex := p.SPK
	if scriptHex == "" {
		scriptHex = p.ScriptPubKey
	}
	if scriptHex == "" {
		scriptHex = p.ScriptPubKey2
	}
	if amount == nil || scriptHex == "" {
		return script.SpentPrevout{}, fmt.Errorf("prevout missing amount or script")
	}
	spk, err := hex.DecodeString(scriptHex)
	if err != nil {
		return script.SpentPrevout{}, err
	}
	return script.SpentPrevout{Amount: *amount, ScriptPubKey: spk}, nil
}

func firstPath(manifestPath string, entry manifestEntry, category string) string {
	values := entry.Files[category]
	if len(values) == 0 {
		return ""
	}
	return filepath.Join(filepath.Dir(manifestPath), values[0])
}

func readHex(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return hex.DecodeString(strings.TrimSpace(string(data)))
}

func failureStage(message string) string {
	lower := strings.ToLower(message)
	for _, item := range []struct {
		stage string
		terms []string
	}{
		{"template", []string{"witness", "scriptpubkey", "template", "p2sh", "p2w", "p2tr"}},
		{"sighash", []string{"sighash", "signature hash", "hash type", "hashtype"}},
		{"opcode", []string{"unsupported opcode", "opcode"}},
		{"taproot", []string{"taproot", "tapscript", "control block", "tapleaf"}},
		{"crypto", []string{"signature", "schnorr", "ecdsa", "der"}},
		{"stack", []string{"stack", "branch", "conditional", "verify failed", "equalverify"}},
	} {
		for _, term := range item.terms {
			if strings.Contains(lower, term) {
				return item.stage
			}
		}
	}
	return "unknown"
}

func commit(root string) string {
	return "unknown"
}

func manifestName(root string, manifestPath string) string {
	if root == "" {
		return manifestPath
	}
	rel, err := filepath.Rel(root, manifestPath)
	if err != nil {
		return manifestPath
	}
	return rel
}
