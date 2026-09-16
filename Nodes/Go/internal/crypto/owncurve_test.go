//go:build owncurve

package crypto

import (
	"encoding/hex"
	"sync"
	"testing"
)

func TestOwnCurveParallelAndUnavailable(t *testing.T) {
	decode := func(s string) []byte {
		b, e := hex.DecodeString(s)
		if e != nil {
			t.Fatal(e)
		}
		return b
	}
	key := decode("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
	msg := decode("281dd50f6f56bc6e867fe73dd614a73c55a647a479704f64804b574cafb0f5c5")
	sig := decode("3044022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179802205e23c47196cc87e523dfb62c5b644dbb626c9867080a27fde59485e5098d33e4")
	v := NewVerifier()
	if v == nil {
		t.Fatal("own_curve unavailable")
	}
	defer v.Close()
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if !v.VerifyECDSA(key, msg, sig) {
				t.Error("parallel verification failed")
			}
		}()
	}
	wg.Wait()
	t.Setenv("GOBITNODE_CRYPTO_BACKEND", "libsecp256k1")
	if NewVerifier() != nil {
		t.Fatal("candidate accepted C backend selection")
	}
	t.Setenv("GOBITNODE_CRYPTO_BACKEND", "unknown")
	if NewVerifier() != nil {
		t.Fatal("candidate accepted unknown backend")
	}
	if Info().NativeAvailable || Info().SelectedBackend != "libsecp256k1-go" {
		t.Fatal("incorrect backend provenance")
	}
}
