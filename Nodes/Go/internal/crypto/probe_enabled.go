//go:build cryptoprobe

package crypto

import (
	"fmt"
	"os"
	"sync"
)

var probeMu sync.Mutex

// Test-build-only observation. No reference implementation is called here.
func probe(op string, key, msg, sig []byte, result string) bool {
	probeMu.Lock()
	defer probeMu.Unlock()
	fmt.Fprintf(os.Stderr, "rb.crypto_call %s %x %x %x %s\n", op, key, msg, sig, result)
	return os.Getenv("RB_CRYPTO_REJECT") == op
}
