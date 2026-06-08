package main

import (
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"rosettabitcoin/nodes/go/internal/crypto"
	"rosettabitcoin/nodes/go/internal/repo"
	"rosettabitcoin/nodes/go/internal/scriptcorpus"
)

type outcomeFile struct {
	Port     string    `json:"port"`
	Backend  string    `json:"backend"`
	Outcomes []outcome `json:"outcomes"`
}

type outcome struct {
	Capability string `json:"capability"`
	Status     string `json:"status"`
	CasePassed int    `json:"case_passed"`
	CaseTotal  int    `json:"case_total"`
	Notes      string `json:"notes,omitempty"`
}

type nativeDoc struct {
	Vectors []nativeVector `json:"vectors"`
}

type nativeVector struct {
	ID                     string `json:"id"`
	Operation              string `json:"operation"`
	Expected               string `json:"expected"`
	PubkeyHex              string `json:"pubkey_hex"`
	XOnlyHex               string `json:"xonly_pubkey_hex"`
	MsgHashHex             string `json:"msg_hash_hex"`
	SignatureHex           string `json:"signature_hex"`
	MerkleRootHex          string `json:"merkle_root_hex"`
	ExpectedOutputXOnlyHex string `json:"expected_output_xonly_hex"`
	ExpectedParity         int    `json:"expected_parity"`
}

func main() {
	kind := flag.String("kind", "", "crypto-vectors or block-connect-backend")
	outcomePath := flag.String("outcome-path", "", "outcome JSON path")
	flag.Parse()
	if *kind == "" || *outcomePath == "" {
		fmt.Fprintln(os.Stderr, "--kind and --outcome-path are required")
		os.Exit(2)
	}

	var outcomes []outcome
	var err error
	switch *kind {
	case "crypto-vectors":
		outcomes, err = cryptoVectorOutcomes()
	case "block-connect-backend":
		outcomes, err = blockConnectOutcomes()
	default:
		err = fmt.Errorf("unknown kind: %s", *kind)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	payload := outcomeFile{Port: "go", Backend: "libsecp256k1", Outcomes: outcomes}
	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := os.MkdirAll(filepath.Dir(*outcomePath), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := os.WriteFile(*outcomePath, append(data, '\n'), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(*outcomePath)
}

func cryptoVectorOutcomes() ([]outcome, error) {
	root, err := repo.Root()
	if err != nil {
		return nil, err
	}
	verifier := crypto.NewVerifier()
	if verifier == nil {
		return []outcome{
			{Capability: "crypto_bip340_vectors", Status: "fail", CasePassed: 0, CaseTotal: 19, Notes: "native verifier unavailable"},
			{Capability: "crypto_libsecp256k1_equivalence", Status: "fail", CasePassed: 0, CaseTotal: 27, Notes: "native verifier unavailable"},
		}, nil
	}
	defer verifier.Close()

	bipPassed, bipTotal, bipNotes, err := runBIP340(filepath.Join(root, "Nodes", "Shared", "testing", "fixtures", "bip340", "test-vectors.csv"), verifier)
	if err != nil {
		return nil, err
	}
	nativePassed, nativeTotal, nativeNotes, err := runNativeVectors(filepath.Join(root, "Nodes", "Shared", "conformance", "fixtures", "native_crypto_v1_vectors.json"), verifier)
	if err != nil {
		return nil, err
	}
	eqPassed := bipPassed + nativePassed
	eqTotal := bipTotal + nativeTotal
	return []outcome{
		{Capability: "crypto_bip340_vectors", Status: status(bipPassed, bipTotal), CasePassed: bipPassed, CaseTotal: bipTotal, Notes: bipNotes},
		{Capability: "crypto_libsecp256k1_equivalence", Status: status(eqPassed, eqTotal), CasePassed: eqPassed, CaseTotal: eqTotal, Notes: strings.Join([]string{bipNotes, nativeNotes}, "; ")},
	}, nil
}

func runBIP340(path string, verifier *crypto.Verifier) (int, int, string, error) {
	file, err := os.Open(path)
	if err != nil {
		return 0, 0, "", err
	}
	defer file.Close()
	rows, err := csv.NewReader(file).ReadAll()
	if err != nil {
		return 0, 0, "", err
	}
	passed := 0
	total := 0
	failures := []string{}
	for _, row := range rows[1:] {
		if len(row) < 7 {
			return 0, 0, "", fmt.Errorf("malformed BIP340 row")
		}
		total++
		pubkey, _ := hex.DecodeString(row[2])
		msg, _ := hex.DecodeString(row[4])
		sig, _ := hex.DecodeString(row[5])
		want := row[6] == "TRUE"
		got := verifier.VerifySchnorrMessage(pubkey, msg, sig)
		if got == want {
			passed++
		} else {
			failures = append(failures, row[0])
		}
	}
	if len(failures) == 0 {
		return passed, total, "all BIP340 vectors matched expected verification result", nil
	}
	return passed, total, "mismatched BIP340 vector indexes: " + strings.Join(failures, ","), nil
}

func runNativeVectors(path string, verifier *crypto.Verifier) (int, int, string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, 0, "", err
	}
	var doc nativeDoc
	if err := json.Unmarshal(data, &doc); err != nil {
		return 0, 0, "", err
	}
	passed := 0
	failures := []string{}
	for _, vector := range doc.Vectors {
		ok, err := nativeVectorMatches(vector, verifier)
		if err != nil || !ok {
			failures = append(failures, vector.ID)
			continue
		}
		passed++
	}
	if len(failures) == 0 {
		return passed, len(doc.Vectors), fmt.Sprintf("native crypto vectors %d/%d", passed, len(doc.Vectors)), nil
	}
	return passed, len(doc.Vectors), "native vector failures: " + strings.Join(failures, ","), nil
}

func nativeVectorMatches(vector nativeVector, verifier *crypto.Verifier) (bool, error) {
	want := vector.Expected == "valid"
	switch vector.Operation {
	case "verify_ecdsa":
		pubkey, _ := hex.DecodeString(vector.PubkeyHex)
		msg, _ := hex.DecodeString(vector.MsgHashHex)
		sig, _ := hex.DecodeString(vector.SignatureHex)
		return verifier.VerifyECDSA(pubkey, msg, sig) == want, nil
	case "verify_schnorr":
		pubkey, _ := hex.DecodeString(vector.XOnlyHex)
		msg, _ := hex.DecodeString(vector.MsgHashHex)
		sig, _ := hex.DecodeString(vector.SignatureHex)
		return verifier.VerifySchnorr(pubkey, msg, sig) == want, nil
	case "taproot_tweak_xonly":
		internal, _ := hex.DecodeString(vector.XOnlyHex)
		merkle, _ := hex.DecodeString(vector.MerkleRootHex)
		tweak := tapTweakHash(internal, merkle)
		result, ok := verifier.TaprootTweakPubkeyXOnly(internal, tweak[:])
		got := ok && hex.EncodeToString(result.OutputXOnly) == vector.ExpectedOutputXOnlyHex && result.Parity == vector.ExpectedParity
		return got == want, nil
	default:
		return false, fmt.Errorf("unknown native crypto operation: %s", vector.Operation)
	}
}

func blockConnectOutcomes() ([]outcome, error) {
	fixtures := []string{"scripts.p2pkh_sighash_single_38010", "scripts.p2tr_scriptpath_44295"}
	passed := 0
	notes := []string{}
	for _, fixture := range fixtures {
		tmp := filepath.Join(os.TempDir(), "gobitnode_"+strings.ReplaceAll(fixture, ".", "_")+"_probe.json")
		summary, err := scriptcorpus.Run("", tmp, fixture)
		_ = os.Remove(tmp)
		if err == nil && summary.Result == "passed" && summary.Passed == summary.FixtureCount {
			passed++
		}
		if err != nil {
			notes = append(notes, fixture+": "+err.Error())
		} else {
			notes = append(notes, fmt.Sprintf("%s result=%s", fixture, summary.Result))
		}
	}
	return []outcome{{Capability: "block_connect_with_backend", Status: status(passed, len(fixtures)), CasePassed: passed, CaseTotal: len(fixtures), Notes: strings.Join(notes, "; ")}}, nil
}

func tapTweakHash(internal, merkle []byte) [32]byte {
	tag := sha256.Sum256([]byte("TapTweak"))
	input := append(append(append([]byte{}, tag[:]...), tag[:]...), internal...)
	input = append(input, merkle...)
	return sha256.Sum256(input)
}

func status(passed, total int) string {
	if passed == total {
		return "pass"
	}
	return "fail"
}
