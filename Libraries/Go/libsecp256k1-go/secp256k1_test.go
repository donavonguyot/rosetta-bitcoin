package secp256k1_test

import (
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"errors"
	secp "github.com/donavonguyot/rosetta-bitcoin/Libraries/Go/libsecp256k1-go"
	"os"
	"testing"
)

func decode(s string) []byte {
	b, e := hex.DecodeString(s)
	if e != nil {
		panic(e)
	}
	return b
}
func tagged(tag string, b []byte) []byte {
	t := sha256.Sum256([]byte(tag))
	h := sha256.New()
	h.Write(t[:])
	h.Write(t[:])
	h.Write(b)
	return h.Sum(nil)
}
func TestSharedVectors(t *testing.T) {
	data, e := os.ReadFile("testdata/native.json")
	if e != nil {
		t.Fatal(e)
	}
	var d struct {
		Vectors []map[string]any `json:"vectors"`
	}
	if e = json.Unmarshal(data, &d); e != nil {
		t.Fatal(e)
	}
	if len(d.Vectors) != 33 {
		t.Fatal("incomplete fixture set")
	}
	for _, v := range d.Vectors {
		t.Run(v["id"].(string), func(t *testing.T) {
			get := func(k string) []byte { s, _ := v[k].(string); return decode(s) }
			var ok bool
			var err error
			switch v["operation"] {
			case "verify_ecdsa":
				ok, err = secp.VerifyECDSA(get("pubkey_hex"), get("msg_hash_hex"), get("signature_hex"))
			case "verify_schnorr":
				ok, err = secp.VerifySchnorr(get("xonly_pubkey_hex"), get("msg_hash_hex"), get("signature_hex"))
			case "taproot_tweak_xonly":
				key := get("xonly_pubkey_hex")
				tweak := tagged("TapTweak", append(append([]byte{}, key...), get("merkle_root_hex")...))
				var r secp.TweakResult
				r, err = secp.AddXOnlyTweak(key, tweak)
				if err == nil {
					p, _ := v["expected_parity"].(float64)
					ok = hex.EncodeToString(r.XOnly[:]) == v["expected_output_xonly_hex"] && int(r.Parity) == int(p)
				}
			default:
				t.Fatal("unhandled operation")
			}
			got := "consensus_invalid"
			if err != nil {
				got = "malformed_input"
			}
			if ok {
				got = "valid"
			}
			if got != v["expected"] {
				t.Fatalf("got %s (%v), want %s", got, err, v["expected"])
			}
		})
	}
}
func TestBIP340(t *testing.T) {
	f, e := os.Open("testdata/bip340.csv")
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	rows, e := csv.NewReader(f).ReadAll()
	if e != nil {
		t.Fatal(e)
	}
	if len(rows) != 20 {
		t.Fatal("incomplete BIP340 fixture set")
	}
	for _, r := range rows[1:] {
		t.Run(r[0], func(t *testing.T) {
			ok, err := secp.VerifySchnorr(decode(r[2]), decode(r[4]), decode(r[5]))
			if ok != (r[6] == "TRUE") {
				t.Fatalf("got %v %v", ok, err)
			}
		})
	}
}
func TestBoundaries(t *testing.T) {
	key := decode("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
	x := key[1:]
	zero := make([]byte, 32)
	r, e := secp.AddXOnlyTweak(x, zero)
	if e != nil || hex.EncodeToString(r.XOnly[:]) != hex.EncodeToString(x) || r.Parity != 0 {
		t.Fatal(r, e)
	}
	n := decode("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")
	if _, e = secp.AddXOnlyTweak(x, n); !errors.Is(e, secp.ErrInvalidScalar) {
		t.Fatal(e)
	}
	n[31]--
	if _, e = secp.AddXOnlyTweak(x, n); !errors.Is(e, secp.ErrInfinity) {
		t.Fatal(e)
	}
	uncompressed := append([]byte{4}, append(append([]byte{}, x...), decode("483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8")...)...)
	for _, prefix := range []byte{4, 6, 7} {
		uncompressed[0] = prefix
		_, e = secp.ParsePublicKey(uncompressed)
		if (e == nil) != (prefix != 7) {
			t.Fatal(prefix, e)
		}
	}
	if ok, e := secp.VerifyECDSA(key, zero, decode("3006020100020101")); ok || e != nil {
		t.Fatal(ok, e)
	}
	if ok, e := secp.VerifyECDSA(key, zero, decode("3006020180020101")); ok || e != nil {
		t.Fatal(ok, e)
	}
	for _, sig := range []string{"300702020001020101", "300602010102010100", "30060201010200"} {
		if _, e := secp.VerifyECDSA(key, zero, decode(sig)); !errors.Is(e, secp.ErrMalformed) {
			t.Fatal(sig, e)
		}
	}
	if _, e := secp.CheckXOnlyTweak(x, zero, x, 2); !errors.Is(e, secp.ErrMalformed) {
		t.Fatal(e)
	}
	high := decode("3045022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798022100a1dc3b8e6933781adc2049d3a49bb2435842447fa73e783dda3dd8a7c6a90d5d")
	low, e := secp.NormalizeLowS(high)
	if e != nil || len(low) != 70 {
		t.Fatal(e)
	}
	again, e := secp.NormalizeLowS(low)
	if e != nil || hex.EncodeToString(low) != hex.EncodeToString(again) {
		t.Fatal(e)
	}
}
func FuzzVerify(f *testing.F) {
	f.Add([]byte{2}, make([]byte, 32), []byte{0x30})
	f.Fuzz(func(t *testing.T, k, m, s []byte) {
		_, _ = secp.VerifyECDSA(k, m, s)
		_, _ = secp.VerifySchnorr(k, m, s)
		_, _ = secp.AddXOnlyTweak(k, m)
	})
}
func BenchmarkOperations(b *testing.B) {
	raw, _ := os.ReadFile("testdata/native.json")
	var d struct{ Vectors []map[string]any }
	json.Unmarshal(raw, &d)
	e := d.Vectors[0]
	key := decode(e["pubkey_hex"].(string))
	msg := decode(e["msg_hash_hex"].(string))
	sig := decode(e["signature_hex"].(string))
	var sk, sm, ss []byte
	for _, v := range d.Vectors {
		if v["operation"] == "verify_schnorr" && v["expected"] == "valid" {
			sk = decode(v["xonly_pubkey_hex"].(string))
			sm = decode(v["msg_hash_hex"].(string))
			ss = decode(v["signature_hex"].(string))
			break
		}
	}
	cases := map[string]func(){"ecdsa/valid": func() { secp.VerifyECDSA(key, msg, sig) }, "ecdsa/invalid": func() { secp.VerifyECDSA(key, make([]byte, 32), sig) }, "schnorr/valid": func() { secp.VerifySchnorr(sk, sm, ss) }, "schnorr/invalid": func() { secp.VerifySchnorr(sk, []byte{0}, ss) }, "parse/valid": func() { secp.ParsePublicKey(key) }, "parse/invalid": func() { secp.ParsePublicKey([]byte{0}) }, "tweak/valid": func() { secp.AddXOnlyTweak(key[1:], msg) }, "tweak/invalid": func() { secp.AddXOnlyTweak(key[1:], []byte{0}) }}
	for name, fn := range cases {
		b.Run(name, func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				fn()
			}
		})
	}
}
