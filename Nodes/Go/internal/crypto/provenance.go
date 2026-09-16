package crypto

// SourceDigest is supplied by the reproducible build harness, never guessed at runtime.
var SourceDigest = "unrecorded"

type Provenance struct {
	Lane           string `json:"lane"`
	Implementation string `json:"implementation"`
	SourceDigest   string `json:"source_digest"`
	Arithmetic     string `json:"arithmetic"`
	Hashing        string `json:"hashing"`
}

func BuildProvenance() Provenance {
	if Info().SelectedBackend == "libsecp256k1-go" {
		return Provenance{"own_curve", "libsecp256k1-go", SourceDigest, "Go math/big", "Go crypto/sha256"}
	}
	return Provenance{"c_binding", Info().SelectedBackend, SourceDigest, "C libsecp256k1", "node hashing"}
}
