//go:build !cryptoprobe

package crypto

func probe(op string, key, msg, sig []byte, result string) bool { return false }
