#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <openssl/sha.h>
#include <rocksdb/c.h>
#include <secp256k1.h>
#include <secp256k1_extrakeys.h>
#include <secp256k1_schnorrsig.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

enum {
  CRYPTO_RESULT_VALID = 0,
  CRYPTO_RESULT_CONSENSUS_INVALID = 1,
  CRYPTO_RESULT_MALFORMED_INPUT = 2,
  CRYPTO_RESULT_UNKNOWN = 3,
};

typedef struct {
  const char *operation;
  const char *pubkey_hex;
  const char *xonly_hex;
  const char *msg_hash_hex;
  const char *signature_hex;
  const char *merkle_root_hex;
  const char *expected_xonly_hex;
  int expected_parity;
} crypto_vector;

static const crypto_vector CRYPTO_VECTORS[] = {
    {"verify_ecdsa", "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798", NULL,
     "281dd50f6f56bc6e867fe73dd614a73c55a647a479704f64804b574cafb0f5c5",
     "3044022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179802205e23c47196cc87e523dfb62c5b644dbb626c9867080a27fde59485e5098d33e4",
     NULL, NULL, -1},
    {"verify_ecdsa", "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798", NULL,
     "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
     "3044022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179802205e23c47196cc87e523dfb62c5b644dbb626c9867080a27fde59485e5098d33e4",
     NULL, NULL, -1},
    {"verify_ecdsa", "", NULL, "0000000000000000000000000000000000000000000000000000000000000000", "",
     NULL, NULL, -1},
    {"verify_schnorr", NULL, "f01d6b9018ab421dd410404cb869072065522bf85734008f105cf385a023a80f",
     "3ad22a0437431f2d102505b27048dfce20b1f90b32fe2116130d2bd4b35084b9",
     "632f89d23c32b7d66873d7ef89e730f44f3d063394f8661e4421469979ac5784c80478f3845b4719c92c339fe1032890f9d96b6b0b44a8ea05da6ce88a133b7b",
     NULL, NULL, -1},
    {"verify_schnorr", NULL, "f01d6b9018ab421dd410404cb869072065522bf85734008f105cf385a023a80f",
     "3ad22a0437431f2d102505b27048dfce20b1f90b32fe2116130d2bd4b35084b9",
     "622f89d23c32b7d66873d7ef89e730f44f3d063394f8661e4421469979ac5784c80478f3845b4719c92c339fe1032890f9d96b6b0b44a8ea05da6ce88a133b7b",
     NULL, NULL, -1},
    {"verify_schnorr", NULL, "0000000000000000000000000000000000000000000000000000000000000000",
     "0000000000000000000000000000000000000000000000000000000000000000", "", NULL, NULL, -1},
    {"taproot_tweak_xonly", NULL, "85a7b790fc9d962493788317e4874a4ab07f1e9c78c773c47f2f6c96df756f05",
     NULL, NULL, "446ba384864eb34196e08044029fb463d97748e4549dfd0e2612f60d74c4f165",
     "4b3e30f94e0ae82945cbb40d83088b8f3bea370c24c575b7788889ad5e64da8b", 1},
    {"taproot_tweak_xonly", NULL, "00", NULL, NULL, "", NULL, -1},
};

static const size_t CRYPTO_VECTOR_COUNT = sizeof(CRYPTO_VECTORS) / sizeof(CRYPTO_VECTORS[0]);

static bool hex_nibble(char c, uint8_t *out) {
  if (c >= '0' && c <= '9') {
    *out = (uint8_t)(c - '0');
    return true;
  }
  if (c >= 'a' && c <= 'f') {
    *out = (uint8_t)(c - 'a' + 10);
    return true;
  }
  if (c >= 'A' && c <= 'F') {
    *out = (uint8_t)(c - 'A' + 10);
    return true;
  }
  return false;
}

static bool hex_to_bytes(const char *hex, uint8_t *out, size_t out_len) {
  const size_t len = strlen(hex);
  if (len != out_len * 2) {
    return false;
  }
  for (size_t i = 0; i < out_len; i++) {
    uint8_t hi = 0;
    uint8_t lo = 0;
    if (!hex_nibble(hex[i * 2], &hi) || !hex_nibble(hex[i * 2 + 1], &lo)) {
      return false;
    }
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  return true;
}

static bool hex_to_bytes_len(const char *hex, size_t hex_len, uint8_t *out, size_t out_len) {
  if (!hex || hex_len != out_len * 2) {
    return false;
  }
  for (size_t i = 0; i < out_len; i++) {
    uint8_t hi = 0;
    uint8_t lo = 0;
    if (!hex_nibble(hex[i * 2], &hi) || !hex_nibble(hex[i * 2 + 1], &lo)) {
      return false;
    }
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  return true;
}

static void bytes_to_hex(const uint8_t *bytes, size_t len, char *out) {
  static const char *alphabet = "0123456789abcdef";
  for (size_t i = 0; i < len; i++) {
    out[i * 2] = alphabet[bytes[i] >> 4];
    out[i * 2 + 1] = alphabet[bytes[i] & 0x0f];
  }
  out[len * 2] = '\0';
}

static void sha256_once(const uint8_t *data, size_t len, uint8_t out[32]) {
  SHA256(data, len, out);
}

static bool taproot_tweak_hash(const uint8_t internal_xonly[32], const char *merkle_root_hex, uint8_t out[32]) {
  uint8_t tag_hash[32];
  sha256_once((const uint8_t *)"TapTweak", 8, tag_hash);

  uint8_t merkle[32];
  size_t merkle_len = 0;
  if (merkle_root_hex && strlen(merkle_root_hex) > 0) {
    if (!hex_to_bytes(merkle_root_hex, merkle, sizeof(merkle))) {
      return false;
    }
    merkle_len = sizeof(merkle);
  }

  uint8_t tagged_payload[128];
  size_t offset = 0;
  memcpy(tagged_payload + offset, tag_hash, sizeof(tag_hash));
  offset += sizeof(tag_hash);
  memcpy(tagged_payload + offset, tag_hash, sizeof(tag_hash));
  offset += sizeof(tag_hash);
  memcpy(tagged_payload + offset, internal_xonly, 32);
  offset += 32;
  if (merkle_len > 0) {
    memcpy(tagged_payload + offset, merkle, merkle_len);
    offset += merkle_len;
  }
  sha256_once(tagged_payload, offset, out);
  return true;
}

static int32_t verify_ecdsa(secp256k1_context *ctx, const crypto_vector *vector) {
  uint8_t pubkey_bytes[33];
  uint8_t msg[32];
  uint8_t sig_bytes[72];
  if (!vector->pubkey_hex || !vector->signature_hex || !vector->msg_hash_hex ||
      !hex_to_bytes(vector->pubkey_hex, pubkey_bytes, sizeof(pubkey_bytes)) ||
      !hex_to_bytes(vector->msg_hash_hex, msg, sizeof(msg))) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }
  const size_t sig_len = strlen(vector->signature_hex) / 2;
  if (sig_len == 0 || sig_len > sizeof(sig_bytes) || !hex_to_bytes(vector->signature_hex, sig_bytes, sig_len)) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }

  secp256k1_pubkey pubkey;
  secp256k1_ecdsa_signature sig;
  if (secp256k1_ec_pubkey_parse(ctx, &pubkey, pubkey_bytes, sizeof(pubkey_bytes)) != 1 ||
      secp256k1_ecdsa_signature_parse_der(ctx, &sig, sig_bytes, sig_len) != 1) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }
  secp256k1_ecdsa_signature_normalize(ctx, &sig, &sig);
  return secp256k1_ecdsa_verify(ctx, &sig, msg, &pubkey) == 1 ? CRYPTO_RESULT_VALID
                                                               : CRYPTO_RESULT_CONSENSUS_INVALID;
}

static int32_t verify_ecdsa_der_bytes(const uint8_t *pubkey_bytes, size_t pubkey_len, const uint8_t *sig_bytes,
                                      size_t sig_len, const uint8_t msg[32]) {
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  if (!ctx) {
    return CRYPTO_RESULT_UNKNOWN;
  }

  secp256k1_pubkey pubkey;
  secp256k1_ecdsa_signature sig;
  int32_t result = CRYPTO_RESULT_MALFORMED_INPUT;
  if (secp256k1_ec_pubkey_parse(ctx, &pubkey, pubkey_bytes, pubkey_len) == 1 &&
      secp256k1_ecdsa_signature_parse_der(ctx, &sig, sig_bytes, sig_len) == 1) {
    secp256k1_ecdsa_signature_normalize(ctx, &sig, &sig);
    result = secp256k1_ecdsa_verify(ctx, &sig, msg, &pubkey) == 1 ? CRYPTO_RESULT_VALID
                                                                  : CRYPTO_RESULT_CONSENSUS_INVALID;
  }
  secp256k1_context_destroy(ctx);
  return result;
}

int32_t mojobitnode_verify_ecdsa_der_hex(const char *pubkey_hex, const char *signature_hex,
                                         const char *msg_hash_hex) {
  if (!pubkey_hex || !signature_hex || !msg_hash_hex) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }
  const size_t pubkey_hex_len = strlen(pubkey_hex);
  const size_t signature_hex_len = strlen(signature_hex);
  const size_t msg_hash_hex_len = strlen(msg_hash_hex);
  const size_t pubkey_len = pubkey_hex_len / 2;
  const size_t sig_len = signature_hex_len / 2;
  if (pubkey_hex_len != pubkey_len * 2 || signature_hex_len != sig_len * 2 || msg_hash_hex_len != 64 ||
      (pubkey_len != 33 && pubkey_len != 65) || sig_len == 0 || sig_len > 72) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }

  uint8_t pubkey_bytes[65];
  uint8_t sig_bytes[72];
  uint8_t msg[32];
  if (!hex_to_bytes(pubkey_hex, pubkey_bytes, pubkey_len) ||
      !hex_to_bytes(signature_hex, sig_bytes, sig_len) || !hex_to_bytes(msg_hash_hex, msg, sizeof(msg))) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }
  return verify_ecdsa_der_bytes(pubkey_bytes, pubkey_len, sig_bytes, sig_len, msg);
}

int32_t mojobitnode_verify_ecdsa_der_hex_len(const char *pubkey_hex, int32_t pubkey_hex_len,
                                             const char *signature_hex, int32_t signature_hex_len,
                                             const char *msg_hash_hex, int32_t msg_hash_hex_len) {
  if (!pubkey_hex || !signature_hex || !msg_hash_hex || pubkey_hex_len < 0 || signature_hex_len < 0 ||
      msg_hash_hex_len != 64) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }
  const size_t pubkey_len = (size_t)pubkey_hex_len / 2;
  const size_t sig_len = (size_t)signature_hex_len / 2;
  if ((size_t)pubkey_hex_len != pubkey_len * 2 || (size_t)signature_hex_len != sig_len * 2 ||
      (pubkey_len != 33 && pubkey_len != 65) || sig_len == 0 || sig_len > 72) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }

  uint8_t pubkey_bytes[65];
  uint8_t sig_bytes[72];
  uint8_t msg[32];
  if (!hex_to_bytes_len(pubkey_hex, (size_t)pubkey_hex_len, pubkey_bytes, pubkey_len) ||
      !hex_to_bytes_len(signature_hex, (size_t)signature_hex_len, sig_bytes, sig_len) ||
      !hex_to_bytes_len(msg_hash_hex, (size_t)msg_hash_hex_len, msg, sizeof(msg))) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }
  return verify_ecdsa_der_bytes(pubkey_bytes, pubkey_len, sig_bytes, sig_len, msg);
}

static int32_t verify_schnorr(secp256k1_context *ctx, const crypto_vector *vector) {
  uint8_t xonly[32];
  uint8_t msg[32];
  uint8_t sig[64];
  if (!vector->xonly_hex || !vector->signature_hex || !vector->msg_hash_hex ||
      !hex_to_bytes(vector->xonly_hex, xonly, sizeof(xonly)) ||
      !hex_to_bytes(vector->msg_hash_hex, msg, sizeof(msg)) ||
      !hex_to_bytes(vector->signature_hex, sig, sizeof(sig))) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }
  secp256k1_xonly_pubkey pubkey;
  if (secp256k1_xonly_pubkey_parse(ctx, &pubkey, xonly) != 1) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }
  return secp256k1_schnorrsig_verify(ctx, sig, msg, sizeof(msg), &pubkey) == 1
             ? CRYPTO_RESULT_VALID
             : CRYPTO_RESULT_CONSENSUS_INVALID;
}

int32_t mojobitnode_verify_schnorr_hex_len(const char *xonly_hex, int32_t xonly_hex_len,
                                           const char *signature_hex, int32_t signature_hex_len,
                                           const char *msg_hash_hex, int32_t msg_hash_hex_len) {
  if (!xonly_hex || !signature_hex || !msg_hash_hex || xonly_hex_len != 64 || signature_hex_len != 128 ||
      msg_hash_hex_len != 64) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }

  uint8_t xonly[32];
  uint8_t sig[64];
  uint8_t msg[32];
  if (!hex_to_bytes_len(xonly_hex, (size_t)xonly_hex_len, xonly, sizeof(xonly)) ||
      !hex_to_bytes_len(signature_hex, (size_t)signature_hex_len, sig, sizeof(sig)) ||
      !hex_to_bytes_len(msg_hash_hex, (size_t)msg_hash_hex_len, msg, sizeof(msg))) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }

  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  if (!ctx) {
    return CRYPTO_RESULT_UNKNOWN;
  }
  secp256k1_xonly_pubkey pubkey;
  int32_t result = CRYPTO_RESULT_MALFORMED_INPUT;
  if (secp256k1_xonly_pubkey_parse(ctx, &pubkey, xonly) == 1) {
    result = secp256k1_schnorrsig_verify(ctx, sig, msg, sizeof(msg), &pubkey) == 1
                 ? CRYPTO_RESULT_VALID
                 : CRYPTO_RESULT_CONSENSUS_INVALID;
  }
  secp256k1_context_destroy(ctx);
  return result;
}

static int32_t verify_taproot(secp256k1_context *ctx, const crypto_vector *vector) {
  uint8_t internal_xonly[32];
  uint8_t tweak[32];
  if (!vector->xonly_hex || !hex_to_bytes(vector->xonly_hex, internal_xonly, sizeof(internal_xonly)) ||
      !taproot_tweak_hash(internal_xonly, vector->merkle_root_hex, tweak)) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }
  secp256k1_xonly_pubkey internal;
  secp256k1_pubkey output;
  secp256k1_xonly_pubkey output_xonly_pubkey;
  uint8_t output_xonly[32];
  int parity = 0;
  if (secp256k1_xonly_pubkey_parse(ctx, &internal, internal_xonly) != 1 ||
      secp256k1_xonly_pubkey_tweak_add(ctx, &output, &internal, tweak) != 1 ||
      secp256k1_xonly_pubkey_from_pubkey(ctx, &output_xonly_pubkey, &parity, &output) != 1 ||
      secp256k1_xonly_pubkey_serialize(ctx, output_xonly, &output_xonly_pubkey) != 1) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }
  char output_hex[65];
  bytes_to_hex(output_xonly, sizeof(output_xonly), output_hex);
  return vector->expected_xonly_hex && strcmp(output_hex, vector->expected_xonly_hex) == 0 &&
                 parity == vector->expected_parity
             ? CRYPTO_RESULT_VALID
             : CRYPTO_RESULT_CONSENSUS_INVALID;
}

int32_t mojobitnode_verify_taproot_tweak_hex_len(const char *internal_xonly_hex, int32_t internal_xonly_hex_len,
                                                 const char *merkle_root_hex, int32_t merkle_root_hex_len,
                                                 const char *expected_xonly_hex, int32_t expected_xonly_hex_len,
                                                 int32_t expected_parity) {
  if (!internal_xonly_hex || !merkle_root_hex || !expected_xonly_hex || internal_xonly_hex_len != 64 ||
      expected_xonly_hex_len != 64 || (merkle_root_hex_len != 0 && merkle_root_hex_len != 64) ||
      (expected_parity != 0 && expected_parity != 1)) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }

  uint8_t internal_xonly[32];
  uint8_t merkle_root[32];
  if (!hex_to_bytes_len(internal_xonly_hex, (size_t)internal_xonly_hex_len, internal_xonly,
                        sizeof(internal_xonly))) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }
  if (merkle_root_hex_len == 64 &&
      !hex_to_bytes_len(merkle_root_hex, (size_t)merkle_root_hex_len, merkle_root, sizeof(merkle_root))) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }

  char merkle_root_buffer[65];
  merkle_root_buffer[0] = '\0';
  if (merkle_root_hex_len == 64) {
    bytes_to_hex(merkle_root, sizeof(merkle_root), merkle_root_buffer);
  }

  uint8_t tweak[32];
  if (!taproot_tweak_hash(internal_xonly, merkle_root_buffer, tweak)) {
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }

  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  if (!ctx) {
    return CRYPTO_RESULT_UNKNOWN;
  }

  secp256k1_xonly_pubkey internal;
  secp256k1_pubkey output;
  secp256k1_xonly_pubkey output_xonly_pubkey;
  uint8_t output_xonly[32];
  int parity = 0;
  int32_t result = CRYPTO_RESULT_MALFORMED_INPUT;
  if (secp256k1_xonly_pubkey_parse(ctx, &internal, internal_xonly) == 1 &&
      secp256k1_xonly_pubkey_tweak_add(ctx, &output, &internal, tweak) == 1 &&
      secp256k1_xonly_pubkey_from_pubkey(ctx, &output_xonly_pubkey, &parity, &output) == 1 &&
      secp256k1_xonly_pubkey_serialize(ctx, output_xonly, &output_xonly_pubkey) == 1) {
    char output_hex[65];
    bytes_to_hex(output_xonly, sizeof(output_xonly), output_hex);
    result = strncmp(output_hex, expected_xonly_hex, (size_t)expected_xonly_hex_len) == 0 &&
                     output_hex[expected_xonly_hex_len] == '\0' && parity == expected_parity
                 ? CRYPTO_RESULT_VALID
                 : CRYPTO_RESULT_CONSENSUS_INVALID;
  }
  secp256k1_context_destroy(ctx);
  return result;
}

static bool ensure_dir(const char *path) {
  char tmp[1024];
  snprintf(tmp, sizeof(tmp), "%s", path);
  const size_t len = strlen(tmp);
  for (size_t i = 1; i < len; i++) {
    if (tmp[i] == '/') {
      tmp[i] = '\0';
      if (mkdir(tmp, 0775) != 0 && errno != EEXIST) {
        return false;
      }
      tmp[i] = '/';
    }
  }
  return mkdir(tmp, 0775) == 0 || errno == EEXIST;
}

int32_t mojobitnode_native_crypto_available(void) {
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  if (!ctx) {
    return 0;
  }
  secp256k1_context_destroy(ctx);
  return 1;
}

int32_t mojobitnode_native_crypto_vector_count(void) {
  return (int32_t)CRYPTO_VECTOR_COUNT;
}

int32_t mojobitnode_native_crypto_vector_actual(int32_t index) {
  if (index < 0 || (size_t)index >= CRYPTO_VECTOR_COUNT) {
    return CRYPTO_RESULT_UNKNOWN;
  }
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  if (!ctx) {
    return CRYPTO_RESULT_UNKNOWN;
  }

  const crypto_vector *vector = &CRYPTO_VECTORS[index];
  int32_t result = CRYPTO_RESULT_UNKNOWN;
  if (strcmp(vector->operation, "verify_ecdsa") == 0) {
    result = verify_ecdsa(ctx, vector);
  } else if (strcmp(vector->operation, "verify_schnorr") == 0) {
    result = verify_schnorr(ctx, vector);
  } else if (strcmp(vector->operation, "taproot_tweak_xonly") == 0) {
    result = verify_taproot(ctx, vector);
  }
  secp256k1_context_destroy(ctx);
  return result;
}

int32_t mojobitnode_native_crypto_probe(void) {
  return mojobitnode_native_crypto_vector_actual(0) == CRYPTO_RESULT_VALID ? 1 : 0;
}

int32_t mojobitnode_storage_probe(const char *datadir) {
  if (!datadir || !datadir[0]) {
    return 0;
  }
  char dbpath[1024];
  snprintf(dbpath, sizeof(dbpath), "%s/chainstate-rocksdb", datadir);
  if (!ensure_dir(datadir)) {
    return 0;
  }

  char *err = NULL;
  rocksdb_options_t *options = rocksdb_options_create();
  rocksdb_options_set_create_if_missing(options, 1);
  rocksdb_t *db = rocksdb_open(options, dbpath, &err);
  if (err) {
    rocksdb_free(err);
    rocksdb_options_destroy(options);
    return 0;
  }

  int32_t mask = 0;
  rocksdb_writeoptions_t *write_options = rocksdb_writeoptions_create();
  rocksdb_readoptions_t *read_options = rocksdb_readoptions_create();
  const char *key1 = "mojo:owned:key1";
  const char *key2 = "mojo:owned:key2";
  const char *value1 = "value1";
  const char *value2 = "value2";

  rocksdb_put(db, write_options, key1, strlen(key1), value1, strlen(value1), &err);
  if (!err) {
    mask |= 1;
  } else {
    rocksdb_free(err);
    err = NULL;
  }

  size_t read_len = 0;
  char *read_value = rocksdb_get(db, read_options, key1, strlen(key1), &read_len, &err);
  if (!err && read_value && read_len == strlen(value1) && memcmp(read_value, value1, read_len) == 0) {
    mask |= 2;
  }
  if (read_value) {
    rocksdb_free(read_value);
  }
  if (err) {
    rocksdb_free(err);
    err = NULL;
  }

  rocksdb_writebatch_t *batch = rocksdb_writebatch_create();
  rocksdb_writebatch_put(batch, key2, strlen(key2), value2, strlen(value2));
  rocksdb_writebatch_delete(batch, key1, strlen(key1));
  rocksdb_write(db, write_options, batch, &err);
  if (!err) {
    mask |= 4;
  } else {
    rocksdb_free(err);
    err = NULL;
  }

  const char *keys[2] = {key1, key2};
  const size_t key_lens[2] = {strlen(key1), strlen(key2)};
  char *values[2] = {NULL, NULL};
  size_t value_lens[2] = {0, 0};
  char *errors[2] = {NULL, NULL};
  rocksdb_multi_get(db, read_options, 2, keys, key_lens, values, value_lens, errors);
  if (!errors[0] && !errors[1] && !values[0] && values[1] && value_lens[1] == strlen(value2) &&
      memcmp(values[1], value2, value_lens[1]) == 0) {
    mask |= 8;
  }
  for (int i = 0; i < 2; i++) {
    if (values[i]) {
      rocksdb_free(values[i]);
    }
    if (errors[i]) {
      rocksdb_free(errors[i]);
    }
  }

  rocksdb_writebatch_destroy(batch);
  rocksdb_readoptions_destroy(read_options);
  rocksdb_writeoptions_destroy(write_options);
  rocksdb_close(db);
  rocksdb_options_destroy(options);
  return mask;
}

int32_t mojobitnode_write_text(const char *path, const char *text) {
  if (!path || !path[0]) {
    return 1;
  }
  FILE *f = fopen(path, "w");
  if (!f) {
    return 0;
  }
  fputs(text ? text : "", f);
  fclose(f);
  return 1;
}
