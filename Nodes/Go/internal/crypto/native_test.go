package crypto

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"rosettabitcoin/nodes/go/internal/repo"
)

func TestNativeCryptoAvailable(t *testing.T) {
	if !Available() {
		t.Fatal("libsecp256k1 native backend unavailable")
	}
}

func TestReusableVerifierVectors(t *testing.T) {
	verifier := NewVerifier()
	if verifier == nil {
		t.Fatal("native verifier unavailable")
	}
	defer verifier.Close()
	if verifier.ContextMode() != "libsecp256k1/reused_context" {
		t.Fatalf("unexpected context mode: %s", verifier.ContextMode())
	}

	doc := struct {
		Vectors []struct {
			Operation    string `json:"operation"`
			PubkeyHex    string `json:"pubkey_hex"`
			XOnlyHex     string `json:"xonly_pubkey_hex"`
			MsgHashHex   string `json:"msg_hash_hex"`
			SignatureHex string `json:"signature_hex"`
			Expected     string `json:"expected"`
		} `json:"vectors"`
	}{}
	root, err := repo.Root()
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(root, "Nodes", "Shared", "conformance", "fixtures", "native_crypto_v1_vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	checkedECDSA := false
	checkedSchnorr := false
	for _, vector := range doc.Vectors {
		switch vector.Operation {
		case "verify_ecdsa":
			pubkey, _ := hex.DecodeString(vector.PubkeyHex)
			msg, _ := hex.DecodeString(vector.MsgHashHex)
			sig, _ := hex.DecodeString(vector.SignatureHex)
			got := verifier.VerifyECDSA(pubkey, msg, sig)
			want := vector.Expected == "valid"
			if got != want {
				t.Fatalf("ECDSA vector %s got %v want %v", vector.MsgHashHex, got, want)
			}
			checkedECDSA = true
		case "verify_schnorr":
			pubkey, _ := hex.DecodeString(vector.XOnlyHex)
			msg, _ := hex.DecodeString(vector.MsgHashHex)
			sig, _ := hex.DecodeString(vector.SignatureHex)
			got := verifier.VerifySchnorr(pubkey, msg, sig)
			want := vector.Expected == "valid"
			if got != want {
				t.Fatalf("Schnorr vector %s got %v want %v", vector.MsgHashHex, got, want)
			}
			checkedSchnorr = true
		}
	}
	if !checkedECDSA || !checkedSchnorr {
		t.Fatal("expected to check both ECDSA and Schnorr vectors")
	}
	if _, ok := verifier.TaprootTweakPubkeyXOnly(make([]byte, 31), make([]byte, 32)); ok {
		t.Fatal("malformed x-only tweak unexpectedly succeeded")
	}
}
