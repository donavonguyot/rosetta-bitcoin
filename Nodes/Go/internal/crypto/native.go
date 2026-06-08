package crypto

/*
#cgo pkg-config: libsecp256k1
#include <secp256k1.h>
#include <secp256k1_extrakeys.h>
#include <secp256k1_schnorrsig.h>
#include <stdlib.h>
*/
import "C"

import "unsafe"

type BackendInfo struct {
	SelectedBackend     string `json:"selected_backend"`
	NativeAvailable     bool   `json:"native_available"`
	NativePackage       string `json:"native_package"`
	ECDSABackend        string `json:"ecdsa_backend"`
	SchnorrBackend      string `json:"schnorr_backend"`
	TaprootTweakBackend string `json:"taproot_tweak_backend"`
}

type Verifier struct {
	ctx *C.secp256k1_context
}

func Info() BackendInfo {
	available := Available()
	backend := "libsecp256k1"
	if !available {
		backend = "unavailable"
	}
	return BackendInfo{
		SelectedBackend:     backend,
		NativeAvailable:     available,
		NativePackage:       "libsecp256k1",
		ECDSABackend:        backend,
		SchnorrBackend:      backend,
		TaprootTweakBackend: backend,
	}
}

func Available() bool {
	verifier := NewVerifier()
	if verifier == nil {
		return false
	}
	verifier.Close()
	return true
}

func NewVerifier() *Verifier {
	ctx := C.secp256k1_context_create(C.SECP256K1_CONTEXT_VERIFY)
	if ctx == nil {
		return nil
	}
	return &Verifier{ctx: ctx}
}

func (v *Verifier) Close() {
	if v == nil || v.ctx == nil {
		return
	}
	C.secp256k1_context_destroy(v.ctx)
	v.ctx = nil
}

func (v *Verifier) ContextMode() string {
	if v == nil || v.ctx == nil {
		return "libsecp256k1/unavailable"
	}
	return "libsecp256k1/reused_context"
}

func VerifyECDSA(pubkey, msg32, derSignature []byte) bool {
	verifier := NewVerifier()
	if verifier == nil {
		return false
	}
	defer verifier.Close()
	return verifier.VerifyECDSA(pubkey, msg32, derSignature)
}

func (v *Verifier) VerifyECDSA(pubkey, msg32, derSignature []byte) bool {
	if v == nil || v.ctx == nil || len(msg32) != 32 || len(pubkey) == 0 || len(derSignature) == 0 {
		return false
	}
	var pk C.secp256k1_pubkey
	if C.secp256k1_ec_pubkey_parse(v.ctx, &pk, (*C.uchar)(unsafe.Pointer(&pubkey[0])), C.size_t(len(pubkey))) != 1 {
		return false
	}
	var sig C.secp256k1_ecdsa_signature
	if C.secp256k1_ecdsa_signature_parse_der(v.ctx, &sig, (*C.uchar)(unsafe.Pointer(&derSignature[0])), C.size_t(len(derSignature))) != 1 {
		return false
	}
	if C.secp256k1_ecdsa_verify(v.ctx, &sig, (*C.uchar)(unsafe.Pointer(&msg32[0])), &pk) == 1 {
		return true
	}
	var normalized C.secp256k1_ecdsa_signature
	if C.secp256k1_ecdsa_signature_normalize(v.ctx, &normalized, &sig) != 1 {
		return false
	}
	return C.secp256k1_ecdsa_verify(v.ctx, &normalized, (*C.uchar)(unsafe.Pointer(&msg32[0])), &pk) == 1
}

func VerifySchnorr(pubkeyXOnly, msg32, sig64 []byte) bool {
	verifier := NewVerifier()
	if verifier == nil {
		return false
	}
	defer verifier.Close()
	return verifier.VerifySchnorr(pubkeyXOnly, msg32, sig64)
}

func (v *Verifier) VerifySchnorr(pubkeyXOnly, msg32, sig64 []byte) bool {
	if v == nil || v.ctx == nil || len(pubkeyXOnly) != 32 || len(msg32) != 32 || len(sig64) != 64 {
		return false
	}
	return v.VerifySchnorrMessage(pubkeyXOnly, msg32, sig64)
}

func (v *Verifier) VerifySchnorrMessage(pubkeyXOnly, message, sig64 []byte) bool {
	if v == nil || v.ctx == nil || len(pubkeyXOnly) != 32 || len(sig64) != 64 {
		return false
	}
	var pk C.secp256k1_xonly_pubkey
	if C.secp256k1_xonly_pubkey_parse(v.ctx, &pk, (*C.uchar)(unsafe.Pointer(&pubkeyXOnly[0]))) != 1 {
		return false
	}
	var msgPtr *C.uchar
	if len(message) > 0 {
		msgPtr = (*C.uchar)(unsafe.Pointer(&message[0]))
	}
	return C.secp256k1_schnorrsig_verify(v.ctx, (*C.uchar)(unsafe.Pointer(&sig64[0])), msgPtr, C.size_t(len(message)), &pk) == 1
}

type TaprootTweakResult struct {
	Parity      int
	OutputXOnly []byte
}

func TaprootTweakPubkeyXOnly(internalXOnly, tweak32 []byte) (TaprootTweakResult, bool) {
	verifier := NewVerifier()
	if verifier == nil {
		return TaprootTweakResult{}, false
	}
	defer verifier.Close()
	return verifier.TaprootTweakPubkeyXOnly(internalXOnly, tweak32)
}

func (v *Verifier) TaprootTweakPubkeyXOnly(internalXOnly, tweak32 []byte) (TaprootTweakResult, bool) {
	if v == nil || v.ctx == nil || len(internalXOnly) != 32 || len(tweak32) != 32 {
		return TaprootTweakResult{}, false
	}
	var internal C.secp256k1_xonly_pubkey
	if C.secp256k1_xonly_pubkey_parse(v.ctx, &internal, (*C.uchar)(unsafe.Pointer(&internalXOnly[0]))) != 1 {
		return TaprootTweakResult{}, false
	}
	var tweaked C.secp256k1_pubkey
	if C.secp256k1_xonly_pubkey_tweak_add(v.ctx, &tweaked, &internal, (*C.uchar)(unsafe.Pointer(&tweak32[0]))) != 1 {
		return TaprootTweakResult{}, false
	}
	var xonly C.secp256k1_xonly_pubkey
	var parity C.int
	if C.secp256k1_xonly_pubkey_from_pubkey(v.ctx, &xonly, &parity, &tweaked) != 1 {
		return TaprootTweakResult{}, false
	}
	out := make([]byte, 32)
	if C.secp256k1_xonly_pubkey_serialize(v.ctx, (*C.uchar)(unsafe.Pointer(&out[0])), &xonly) != 1 {
		return TaprootTweakResult{}, false
	}
	return TaprootTweakResult{Parity: int(parity), OutputXOnly: out}, true
}
