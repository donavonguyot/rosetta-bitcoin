#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <rocksdb/c.h>
#include <secp256k1.h>
#include <secp256k1_extrakeys.h>
#include <secp256k1_schnorrsig.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

typedef struct {
  rocksdb_t *db;
  rocksdb_cache_t *block_cache;
  rocksdb_block_based_table_options_t *block_options;
  rocksdb_filterpolicy_t *filter_policy;
} mojo_rocksdb_handle;

enum {
  CRYPTO_RESULT_VALID = 0,
  CRYPTO_RESULT_CONSENSUS_INVALID = 1,
  CRYPTO_RESULT_MALFORMED_INPUT = 2,
  CRYPTO_RESULT_UNKNOWN = 3,
};

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

static int64_t monotonic_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
    return 0;
  }
  return ((int64_t)ts.tv_sec * 1000) + ((int64_t)ts.tv_nsec / 1000000);
}

static atomic_llong crypto_ecdsa_calls = 0;
static atomic_llong crypto_ecdsa_ms = 0;
static atomic_llong crypto_schnorr_calls = 0;
static atomic_llong crypto_schnorr_ms = 0;
static atomic_llong crypto_taproot_tweak_calls = 0;
static atomic_llong crypto_taproot_tweak_ms = 0;

static pthread_once_t crypto_profile_once = PTHREAD_ONCE_INIT;
static bool crypto_profile_enabled = false;

static void init_crypto_profile(void) {
  const char *value = getenv("MOJOBITNODE_PROFILE_CRYPTO");
  crypto_profile_enabled =
      value && (strcmp(value, "1") == 0 || strcmp(value, "true") == 0 || strcmp(value, "TRUE") == 0);
}

static bool should_profile_crypto(void) {
  pthread_once(&crypto_profile_once, init_crypto_profile);
  return crypto_profile_enabled;
}

static void record_crypto_ms(atomic_llong *metric, int64_t started) {
  if (started != 0) {
    atomic_fetch_add(metric, monotonic_ms() - started);
  }
}

static uint32_t read_u32_be(const uint8_t *bytes) {
  return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) |
         (uint32_t)bytes[3];
}

static void write_u32_be(uint8_t *bytes, uint32_t value) {
  bytes[0] = (uint8_t)((value >> 24) & 0xff);
  bytes[1] = (uint8_t)((value >> 16) & 0xff);
  bytes[2] = (uint8_t)((value >> 8) & 0xff);
  bytes[3] = (uint8_t)(value & 0xff);
}

static mojo_rocksdb_handle *rocks_handle(int64_t handle) {
  return (mojo_rocksdb_handle *)(intptr_t)handle;
}

int32_t mojobitnode_crypto_metrics_reset(void) {
  atomic_store(&crypto_ecdsa_calls, 0);
  atomic_store(&crypto_ecdsa_ms, 0);
  atomic_store(&crypto_schnorr_calls, 0);
  atomic_store(&crypto_schnorr_ms, 0);
  atomic_store(&crypto_taproot_tweak_calls, 0);
  atomic_store(&crypto_taproot_tweak_ms, 0);
  return 1;
}

int64_t mojobitnode_crypto_metric_len(const char *name, int32_t name_len) {
  if (!name || name_len < 0) {
    return -1;
  }
  if (name_len == 11 && strncmp(name, "ecdsa_calls", (size_t)name_len) == 0) {
    return atomic_load(&crypto_ecdsa_calls);
  }
  if (name_len == 8 && strncmp(name, "ecdsa_ms", (size_t)name_len) == 0) {
    return atomic_load(&crypto_ecdsa_ms);
  }
  if (name_len == 13 && strncmp(name, "schnorr_calls", (size_t)name_len) == 0) {
    return atomic_load(&crypto_schnorr_calls);
  }
  if (name_len == 10 && strncmp(name, "schnorr_ms", (size_t)name_len) == 0) {
    return atomic_load(&crypto_schnorr_ms);
  }
  if (name_len == 19 && strncmp(name, "taproot_tweak_calls", (size_t)name_len) == 0) {
    return atomic_load(&crypto_taproot_tweak_calls);
  }
  if (name_len == 16 && strncmp(name, "taproot_tweak_ms", (size_t)name_len) == 0) {
    return atomic_load(&crypto_taproot_tweak_ms);
  }
  return -1;
}

static pthread_once_t verify_context_once = PTHREAD_ONCE_INIT;
static secp256k1_context *verify_context = NULL;

static void init_verify_context(void) {
  verify_context = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
}

static secp256k1_context *shared_verify_context(void) {
  pthread_once(&verify_context_once, init_verify_context);
  return verify_context;
}

static int32_t verify_ecdsa_der_bytes(const uint8_t *pubkey_bytes, size_t pubkey_len, const uint8_t *sig_bytes,
                                      size_t sig_len, const uint8_t msg[32]) {
  secp256k1_context *ctx = shared_verify_context();
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
  return result;
}

int32_t mojobitnode_verify_ecdsa_der_bytes_len(const uint8_t *pubkey_bytes, int32_t pubkey_len,
                                               const uint8_t *signature_bytes, int32_t signature_len,
                                               const uint8_t *msg_hash_bytes, int32_t msg_hash_len) {
  int64_t started = should_profile_crypto() ? monotonic_ms() : 0;
  atomic_fetch_add(&crypto_ecdsa_calls, 1);
  if (!pubkey_bytes || !signature_bytes || !msg_hash_bytes || (pubkey_len != 33 && pubkey_len != 65) ||
      signature_len <= 0 || signature_len > 72 || msg_hash_len != 32) {
    record_crypto_ms(&crypto_ecdsa_ms, started);
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }
  int32_t result = verify_ecdsa_der_bytes(pubkey_bytes, (size_t)pubkey_len, signature_bytes, (size_t)signature_len,
                                          msg_hash_bytes);
  record_crypto_ms(&crypto_ecdsa_ms, started);
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

  secp256k1_context *ctx = shared_verify_context();
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
  return result;
}

int32_t mojobitnode_verify_schnorr_bytes_len(const uint8_t *xonly_bytes, int32_t xonly_len,
                                             const uint8_t *signature_bytes, int32_t signature_len,
                                             const uint8_t *msg_hash_bytes, int32_t msg_hash_len) {
  int64_t started = should_profile_crypto() ? monotonic_ms() : 0;
  atomic_fetch_add(&crypto_schnorr_calls, 1);
  if (!xonly_bytes || !signature_bytes || !msg_hash_bytes || xonly_len != 32 || signature_len != 64 ||
      msg_hash_len != 32) {
    record_crypto_ms(&crypto_schnorr_ms, started);
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }

  secp256k1_context *ctx = shared_verify_context();
  if (!ctx) {
    record_crypto_ms(&crypto_schnorr_ms, started);
    return CRYPTO_RESULT_UNKNOWN;
  }
  secp256k1_xonly_pubkey pubkey;
  int32_t result = CRYPTO_RESULT_MALFORMED_INPUT;
  if (secp256k1_xonly_pubkey_parse(ctx, &pubkey, xonly_bytes) == 1) {
    result = secp256k1_schnorrsig_verify(ctx, signature_bytes, msg_hash_bytes, (size_t)msg_hash_len, &pubkey) == 1
                 ? CRYPTO_RESULT_VALID
                 : CRYPTO_RESULT_CONSENSUS_INVALID;
  }
  record_crypto_ms(&crypto_schnorr_ms, started);
  return result;
}

int32_t mojobitnode_verify_taproot_tweak_precomputed_bytes_len(const uint8_t *internal_xonly,
                                                               int32_t internal_xonly_len,
                                                               const uint8_t *tweak,
                                                               int32_t tweak_len,
                                                               const uint8_t *expected_xonly,
                                                               int32_t expected_xonly_len,
                                                               int32_t expected_parity) {
  int64_t started = should_profile_crypto() ? monotonic_ms() : 0;
  atomic_fetch_add(&crypto_taproot_tweak_calls, 1);
  if (!internal_xonly || !tweak || !expected_xonly || internal_xonly_len != 32 || tweak_len != 32 ||
      expected_xonly_len != 32 || (expected_parity != 0 && expected_parity != 1)) {
    record_crypto_ms(&crypto_taproot_tweak_ms, started);
    return CRYPTO_RESULT_MALFORMED_INPUT;
  }

  secp256k1_context *ctx = shared_verify_context();
  if (!ctx) {
    record_crypto_ms(&crypto_taproot_tweak_ms, started);
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
    result = memcmp(output_xonly, expected_xonly, 32) == 0 && parity == expected_parity
                 ? CRYPTO_RESULT_VALID
                 : CRYPTO_RESULT_CONSENSUS_INVALID;
  }
  record_crypto_ms(&crypto_taproot_tweak_ms, started);
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

static bool copy_string_len(const char *src, int32_t src_len, char *dst, size_t dst_len) {
  if (!src || src_len < 0 || (size_t)src_len >= dst_len) {
    return false;
  }
  memcpy(dst, src, (size_t)src_len);
  dst[src_len] = '\0';
  return true;
}

int64_t mojobitnode_now_ms(void) {
  return monotonic_ms();
}

int32_t mojobitnode_socket_connect_len(const char *host, int32_t host_len, const char *port, int32_t port_len) {
  char host_buf[256];
  char port_buf[32];
  if (!copy_string_len(host, host_len, host_buf, sizeof(host_buf)) ||
      !copy_string_len(port, port_len, port_buf, sizeof(port_buf))) {
    return -1;
  }

  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;

  struct addrinfo *result = NULL;
  if (getaddrinfo(host_buf, port_buf, &hints, &result) != 0) {
    return -2;
  }

  int fd = -1;
  for (struct addrinfo *ai = result; ai != NULL; ai = ai->ai_next) {
    fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0) {
      continue;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct timeval read_timeout = {.tv_sec = 120, .tv_usec = 0};
    struct timeval write_timeout = {.tv_sec = 30, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &read_timeout, sizeof(read_timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &write_timeout, sizeof(write_timeout));
    if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
      break;
    }
    close(fd);
    fd = -1;
  }
  freeaddrinfo(result);
  return fd;
}

int32_t mojobitnode_socket_close(int32_t fd) {
  if (fd < 0) {
    return 0;
  }
  return close(fd) == 0 ? 1 : 0;
}

int32_t mojobitnode_socket_send_all(int32_t fd, const uint8_t *bytes, int32_t len) {
  if (fd < 0 || !bytes || len < 0) {
    return 0;
  }
  int32_t offset = 0;
  while (offset < len) {
    ssize_t n = send(fd, bytes + offset, (size_t)(len - offset), 0);
    if (n <= 0) {
      return 0;
    }
    offset += (int32_t)n;
  }
  return 1;
}

int32_t mojobitnode_socket_recv_exact(int32_t fd, uint8_t *bytes, int32_t len) {
  if (fd < 0 || !bytes || len < 0) {
    return 0;
  }
  int32_t offset = 0;
  while (offset < len) {
    ssize_t n = recv(fd, bytes + offset, (size_t)(len - offset), 0);
    if (n <= 0) {
      return 0;
    }
    offset += (int32_t)n;
  }
  return 1;
}

int64_t mojobitnode_rocksdb_open_len(const char *datadir, int32_t datadir_len) {
  char dir_buf[1024];
  if (!copy_string_len(datadir, datadir_len, dir_buf, sizeof(dir_buf))) {
    return 0;
  }
  char dbpath[1200];
  snprintf(dbpath, sizeof(dbpath), "%s/chainstate-rocksdb", dir_buf);
  if (!ensure_dir(dir_buf)) {
    return 0;
  }

  char *err = NULL;
  rocksdb_options_t *options = rocksdb_options_create();
  rocksdb_options_set_create_if_missing(options, 1);
  rocksdb_options_increase_parallelism(options, 4);
  rocksdb_options_set_write_buffer_size(options, 64 * 1024 * 1024);
  rocksdb_options_set_max_write_buffer_number(options, 4);
  rocksdb_options_set_max_background_jobs(options, 4);

  rocksdb_cache_t *block_cache = rocksdb_cache_create_lru(256 * 1024 * 1024);
  rocksdb_block_based_table_options_t *block_options = rocksdb_block_based_options_create();
  rocksdb_filterpolicy_t *filter_policy = rocksdb_filterpolicy_create_bloom(10.0);
  if (!block_cache || !block_options || !filter_policy) {
    if (filter_policy) {
      rocksdb_filterpolicy_destroy(filter_policy);
    }
    if (block_options) {
      rocksdb_block_based_options_destroy(block_options);
    }
    if (block_cache) {
      rocksdb_cache_destroy(block_cache);
    }
    rocksdb_options_destroy(options);
    return 0;
  }
  rocksdb_block_based_options_set_block_cache(block_options, block_cache);
  rocksdb_block_based_options_set_filter_policy(block_options, filter_policy);
  rocksdb_block_based_options_set_cache_index_and_filter_blocks(block_options, 1);
  rocksdb_block_based_options_set_cache_index_and_filter_blocks_with_high_priority(block_options, 1);
  rocksdb_block_based_options_set_pin_l0_filter_and_index_blocks_in_cache(block_options, 1);
  rocksdb_options_set_block_based_table_factory(options, block_options);

  rocksdb_t *db = rocksdb_open(options, dbpath, &err);
  rocksdb_options_destroy(options);
  if (err) {
    rocksdb_free(err);
    if (db) {
      rocksdb_close(db);
    }
    rocksdb_filterpolicy_destroy(filter_policy);
    rocksdb_block_based_options_destroy(block_options);
    rocksdb_cache_destroy(block_cache);
    return 0;
  }
  if (!db) {
    rocksdb_filterpolicy_destroy(filter_policy);
    rocksdb_block_based_options_destroy(block_options);
    rocksdb_cache_destroy(block_cache);
    return 0;
  }
  mojo_rocksdb_handle *wrapped = (mojo_rocksdb_handle *)calloc(1, sizeof(mojo_rocksdb_handle));
  if (!wrapped) {
    rocksdb_close(db);
    rocksdb_filterpolicy_destroy(filter_policy);
    rocksdb_block_based_options_destroy(block_options);
    rocksdb_cache_destroy(block_cache);
    return 0;
  }
  wrapped->db = db;
  wrapped->block_cache = block_cache;
  wrapped->block_options = block_options;
  wrapped->filter_policy = filter_policy;
  return (int64_t)(intptr_t)wrapped;
}

int32_t mojobitnode_rocksdb_close_handle(int64_t handle) {
  mojo_rocksdb_handle *wrapped = rocks_handle(handle);
  if (!wrapped) {
    return 0;
  }
  if (wrapped->db) {
    rocksdb_close(wrapped->db);
  }
  /*
   * RocksDB's C API stores table option internals behind shared ownership after
   * open. The faster ports keep these process-lifetime objects rather than
   * tearing them down on DB close, which avoids double-freeing option internals
   * on macOS/Homebrew RocksDB.
   */
  free(wrapped);
  return 1;
}

int32_t mojobitnode_rocksdb_put(int64_t handle, const uint8_t *key, int32_t key_len, const uint8_t *value,
                                int32_t value_len) {
  mojo_rocksdb_handle *wrapped = rocks_handle(handle);
  if (!wrapped || !wrapped->db || !key || key_len < 0 || !value || value_len < 0) {
    return 0;
  }
  char *err = NULL;
  rocksdb_writeoptions_t *write_options = rocksdb_writeoptions_create();
  rocksdb_put(wrapped->db, write_options, (const char *)key, (size_t)key_len, (const char *)value,
              (size_t)value_len, &err);
  rocksdb_writeoptions_destroy(write_options);
  if (err) {
    rocksdb_free(err);
    return 0;
  }
  return 1;
}

int32_t mojobitnode_rocksdb_delete(int64_t handle, const uint8_t *key, int32_t key_len) {
  mojo_rocksdb_handle *wrapped = rocks_handle(handle);
  if (!wrapped || !wrapped->db || !key || key_len < 0) {
    return 0;
  }
  char *err = NULL;
  rocksdb_writeoptions_t *write_options = rocksdb_writeoptions_create();
  rocksdb_delete(wrapped->db, write_options, (const char *)key, (size_t)key_len, &err);
  rocksdb_writeoptions_destroy(write_options);
  if (err) {
    rocksdb_free(err);
    return 0;
  }
  return 1;
}

int64_t mojobitnode_rocksdb_batch_create(void) {
  rocksdb_writebatch_t *batch = rocksdb_writebatch_create();
  return (int64_t)(intptr_t)batch;
}

int32_t mojobitnode_rocksdb_batch_put(int64_t batch_handle, const uint8_t *key, int32_t key_len,
                                      const uint8_t *value, int32_t value_len) {
  rocksdb_writebatch_t *batch = (rocksdb_writebatch_t *)(intptr_t)batch_handle;
  if (!batch || !key || key_len < 0 || !value || value_len < 0) {
    return 0;
  }
  rocksdb_writebatch_put(batch, (const char *)key, (size_t)key_len, (const char *)value, (size_t)value_len);
  return 1;
}

int32_t mojobitnode_rocksdb_batch_delete(int64_t batch_handle, const uint8_t *key, int32_t key_len) {
  rocksdb_writebatch_t *batch = (rocksdb_writebatch_t *)(intptr_t)batch_handle;
  if (!batch || !key || key_len < 0) {
    return 0;
  }
  rocksdb_writebatch_delete(batch, (const char *)key, (size_t)key_len);
  return 1;
}

int32_t mojobitnode_rocksdb_batch_write(int64_t handle, int64_t batch_handle) {
  mojo_rocksdb_handle *wrapped = rocks_handle(handle);
  rocksdb_writebatch_t *batch = (rocksdb_writebatch_t *)(intptr_t)batch_handle;
  if (!wrapped || !wrapped->db || !batch) {
    return 0;
  }
  char *err = NULL;
  rocksdb_writeoptions_t *write_options = rocksdb_writeoptions_create();
  rocksdb_write(wrapped->db, write_options, batch, &err);
  rocksdb_writeoptions_destroy(write_options);
  if (err) {
    rocksdb_free(err);
    return 0;
  }
  return 1;
}

int32_t mojobitnode_rocksdb_batch_destroy(int64_t batch_handle) {
  rocksdb_writebatch_t *batch = (rocksdb_writebatch_t *)(intptr_t)batch_handle;
  if (!batch) {
    return 0;
  }
  rocksdb_writebatch_destroy(batch);
  return 1;
}

int32_t mojobitnode_rocksdb_get(int64_t handle, const uint8_t *key, int32_t key_len, uint8_t *out,
                                int32_t out_cap) {
  mojo_rocksdb_handle *wrapped = rocks_handle(handle);
  if (!wrapped || !wrapped->db || !key || key_len < 0 || !out || out_cap < 0) {
    return -1;
  }
  char *err = NULL;
  size_t value_len = 0;
  rocksdb_readoptions_t *read_options = rocksdb_readoptions_create();
  char *value = rocksdb_get(wrapped->db, read_options, (const char *)key, (size_t)key_len, &value_len, &err);
  rocksdb_readoptions_destroy(read_options);
  if (err) {
    rocksdb_free(err);
    return -1;
  }
  if (!value) {
    return -2;
  }
  if (value_len > (size_t)out_cap) {
    rocksdb_free(value);
    return -3;
  }
  memcpy(out, value, value_len);
  rocksdb_free(value);
  return (int32_t)value_len;
}

int32_t mojobitnode_rocksdb_multi_get_packed(int64_t handle, const uint8_t *packed_keys, int32_t packed_keys_len,
                                             uint8_t *out, int32_t out_cap) {
  mojo_rocksdb_handle *wrapped = rocks_handle(handle);
  if (!wrapped || !wrapped->db || !packed_keys || packed_keys_len < 4 || !out || out_cap < 4) {
    return -1;
  }
  const uint8_t *cursor = packed_keys;
  const uint8_t *end = packed_keys + packed_keys_len;
  uint32_t count = read_u32_be(cursor);
  cursor += 4;
  if (count > 1000000U) {
    return -1;
  }

  const char **key_ptrs = (const char **)calloc(count ? count : 1, sizeof(char *));
  size_t *key_lens = (size_t *)calloc(count ? count : 1, sizeof(size_t));
  char **value_ptrs = (char **)calloc(count ? count : 1, sizeof(char *));
  size_t *value_lens = (size_t *)calloc(count ? count : 1, sizeof(size_t));
  char **errs = (char **)calloc(count ? count : 1, sizeof(char *));
  if (!key_ptrs || !key_lens || !value_ptrs || !value_lens || !errs) {
    free(key_ptrs);
    free(key_lens);
    free(value_ptrs);
    free(value_lens);
    free(errs);
    return -1;
  }

  for (uint32_t i = 0; i < count; i++) {
    if (cursor + 4 > end) {
      free(key_ptrs);
      free(key_lens);
      free(value_ptrs);
      free(value_lens);
      free(errs);
      return -1;
    }
    uint32_t key_len = read_u32_be(cursor);
    cursor += 4;
    if (cursor + key_len > end) {
      free(key_ptrs);
      free(key_lens);
      free(value_ptrs);
      free(value_lens);
      free(errs);
      return -1;
    }
    key_ptrs[i] = (const char *)cursor;
    key_lens[i] = (size_t)key_len;
    cursor += key_len;
  }
  if (cursor != end) {
    free(key_ptrs);
    free(key_lens);
    free(value_ptrs);
    free(value_lens);
    free(errs);
    return -1;
  }

  rocksdb_readoptions_t *read_options = rocksdb_readoptions_create();
  rocksdb_multi_get(wrapped->db, read_options, (size_t)count, key_ptrs, key_lens, value_ptrs, value_lens, errs);
  rocksdb_readoptions_destroy(read_options);

  size_t needed = 4;
  bool has_error = false;
  for (uint32_t i = 0; i < count; i++) {
    if (errs[i]) {
      has_error = true;
    }
    needed += 5;
    if (value_ptrs[i]) {
      needed += value_lens[i];
    }
  }
  if (has_error) {
    for (uint32_t i = 0; i < count; i++) {
      if (errs[i]) {
        rocksdb_free(errs[i]);
      }
      if (value_ptrs[i]) {
        rocksdb_free(value_ptrs[i]);
      }
    }
    free(key_ptrs);
    free(key_lens);
    free(value_ptrs);
    free(value_lens);
    free(errs);
    return -1;
  }
  if (needed > (size_t)out_cap) {
    for (uint32_t i = 0; i < count; i++) {
      if (value_ptrs[i]) {
        rocksdb_free(value_ptrs[i]);
      }
    }
    free(key_ptrs);
    free(key_lens);
    free(value_ptrs);
    free(value_lens);
    free(errs);
    return -3;
  }

  uint8_t *out_cursor = out;
  write_u32_be(out_cursor, count);
  out_cursor += 4;
  for (uint32_t i = 0; i < count; i++) {
    if (value_ptrs[i]) {
      *out_cursor++ = 0;
      write_u32_be(out_cursor, (uint32_t)value_lens[i]);
      out_cursor += 4;
      memcpy(out_cursor, value_ptrs[i], value_lens[i]);
      out_cursor += value_lens[i];
      rocksdb_free(value_ptrs[i]);
    } else {
      *out_cursor++ = 1;
      write_u32_be(out_cursor, 0);
      out_cursor += 4;
    }
  }

  free(key_ptrs);
  free(key_lens);
  free(value_ptrs);
  free(value_lens);
  free(errs);
  return (int32_t)(out_cursor - out);
}

int32_t mojobitnode_native_crypto_available(void) {
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  if (!ctx) {
    return 0;
  }
  secp256k1_context_destroy(ctx);
  return 1;
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

int32_t mojobitnode_write_text_len(
    const char *path,
    int32_t path_len,
    const char *text,
    int32_t text_len) {
  char path_copy[4096];
  if (!copy_string_len(path, path_len, path_copy, sizeof(path_copy)) || !path_copy[0]) {
    return 1;
  }
  FILE *f = fopen(path_copy, "w");
  if (!f) {
    return 0;
  }
  if (text && text_len > 0) {
    size_t written = fwrite(text, 1, (size_t)text_len, f);
    if (written != (size_t)text_len) {
      fclose(f);
      return 0;
    }
  }
  fclose(f);
  return 1;
}
