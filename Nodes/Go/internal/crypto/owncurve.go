//go:build owncurve

package crypto

import (
	"fmt"
	secp "github.com/donavonguyot/rosetta-bitcoin/Libraries/Go/libsecp256k1-go"
	"os"
)

const ownBackend = "libsecp256k1-go"

type Verifier struct{ closed bool }

func Info() BackendInfo {
	return BackendInfo{SelectedBackend: ownBackend, NativeAvailable: false, NativePackage: "none", ECDSABackend: ownBackend, SchnorrBackend: ownBackend, TaprootTweakBackend: ownBackend}
}
func Available() bool { return true }
func NewVerifier() *Verifier {
	s := os.Getenv("GOBITNODE_CRYPTO_BACKEND")
	if s != "" && s != "own_curve" && s != ownBackend {
		return nil
	}
	return &Verifier{}
}
func (v *Verifier) Close() {
	if v != nil {
		v.closed = true
	}
}
func (v *Verifier) ContextMode() string {
	if v == nil || v.closed {
		return ownBackend + "/unavailable"
	}
	return ownBackend + "/reused_context"
}
func (v *Verifier) VerifyECDSA(key, msg, sig []byte) bool {
	if v == nil || v.closed {
		return false
	}
	ok, err := secp.VerifyECDSA(key, msg, sig)
	if probe("ecdsa", key, msg, sig, fmt.Sprint(err == nil && ok)) {
		return false
	}
	return err == nil && ok
}
func VerifyECDSA(key, msg, sig []byte) bool {
	v := NewVerifier()
	defer v.Close()
	return v.VerifyECDSA(key, msg, sig)
}
func (v *Verifier) VerifySchnorr(key, msg, sig []byte) bool {
	if len(msg) != 32 {
		return false
	}
	return v.VerifySchnorrMessage(key, msg, sig)
}
func (v *Verifier) VerifySchnorrMessage(key, msg, sig []byte) bool {
	if v == nil || v.closed {
		return false
	}
	ok, err := secp.VerifySchnorr(key, msg, sig)
	if probe("schnorr", key, msg, sig, fmt.Sprint(err == nil && ok)) {
		return false
	}
	return err == nil && ok
}
func VerifySchnorr(key, msg, sig []byte) bool {
	v := NewVerifier()
	defer v.Close()
	return v.VerifySchnorr(key, msg, sig)
}
func (v *Verifier) TaprootTweakPubkeyXOnly(key, tweak []byte) (TaprootTweakResult, bool) {
	if v == nil || v.closed {
		return TaprootTweakResult{}, false
	}
	r, err := secp.AddXOnlyTweak(key, tweak)
	result := "false"
	if err == nil {
		result = fmt.Sprintf("%x:%d", r.XOnly, r.Parity)
	}
	if probe("tweak", key, tweak, nil, result) {
		return TaprootTweakResult{}, false
	}
	if err != nil {
		return TaprootTweakResult{}, false
	}
	return TaprootTweakResult{Parity: int(r.Parity), OutputXOnly: r.XOnly[:]}, true
}
func TaprootTweakPubkeyXOnly(key, tweak []byte) (TaprootTweakResult, bool) {
	v := NewVerifier()
	defer v.Close()
	return v.TaprootTweakPubkeyXOnly(key, tweak)
}
