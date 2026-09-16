#include <stddef.h>
#include <stdint.h>
#include <openssl/sha.h>
/* Only a native primitive. Digest composition and preimage choice live in IR. */
int rn_sha256(const unsigned char *data, uint64_t size, unsigned char *out) {
    return SHA256(data, (size_t)size, out) != NULL;
}
