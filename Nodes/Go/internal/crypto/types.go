package crypto

type BackendInfo struct {
	SelectedBackend     string `json:"selected_backend"`
	NativeAvailable     bool   `json:"native_available"`
	NativePackage       string `json:"native_package"`
	ECDSABackend        string `json:"ecdsa_backend"`
	SchnorrBackend      string `json:"schnorr_backend"`
	TaprootTweakBackend string `json:"taproot_tweak_backend"`
}

type TaprootTweakResult struct {
	Parity      int
	OutputXOnly []byte
}
