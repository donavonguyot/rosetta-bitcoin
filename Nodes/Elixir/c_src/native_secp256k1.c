#include <string.h>

#include "erl_nif.h"
#include "secp256k1.h"
#include "secp256k1_extrakeys.h"
#include "secp256k1_schnorrsig.h"

static secp256k1_context *CTX = NULL;
static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;

static ERL_NIF_TERM make_error(ErlNifEnv *env, const char *message) {
  return enif_make_tuple2(env, atom_error, enif_make_string(env, message, ERL_NIF_LATIN1));
}

static int bin(ErlNifEnv *env, ERL_NIF_TERM term, ErlNifBinary *out) {
  return enif_inspect_binary(env, term, out);
}

static ERL_NIF_TERM verify_der_signature_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 3) return enif_make_badarg(env);
  ErlNifBinary pubkey_bin, msg_bin, sig_bin;
  if (!bin(env, argv[0], &pubkey_bin) || !bin(env, argv[1], &msg_bin) || !bin(env, argv[2], &sig_bin)) {
    return enif_make_badarg(env);
  }
  if (msg_bin.size != 32) return enif_make_atom(env, "false");

  secp256k1_pubkey pubkey;
  secp256k1_ecdsa_signature sig;
  if (!secp256k1_ec_pubkey_parse(CTX, &pubkey, pubkey_bin.data, pubkey_bin.size)) {
    return enif_make_atom(env, "false");
  }
  if (!secp256k1_ecdsa_signature_parse_der(CTX, &sig, sig_bin.data, sig_bin.size)) {
    return enif_make_atom(env, "false");
  }
  secp256k1_ecdsa_signature normalized;
  secp256k1_ecdsa_signature_normalize(CTX, &normalized, &sig);
  int valid = secp256k1_ecdsa_verify(CTX, &normalized, msg_bin.data, &pubkey);
  return enif_make_atom(env, valid ? "true" : "false");
}

static ERL_NIF_TERM verify_schnorr_signature_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 3) return enif_make_badarg(env);
  ErlNifBinary pubkey_bin, msg_bin, sig_bin;
  if (!bin(env, argv[0], &pubkey_bin) || !bin(env, argv[1], &msg_bin) || !bin(env, argv[2], &sig_bin)) {
    return enif_make_badarg(env);
  }
  if (pubkey_bin.size != 32 || msg_bin.size != 32 || sig_bin.size != 64) {
    return enif_make_atom(env, "false");
  }

  secp256k1_xonly_pubkey pubkey;
  if (!secp256k1_xonly_pubkey_parse(CTX, &pubkey, pubkey_bin.data)) {
    return enif_make_atom(env, "false");
  }
  int valid = secp256k1_schnorrsig_verify(CTX, sig_bin.data, msg_bin.data, 32, &pubkey);
  return enif_make_atom(env, valid ? "true" : "false");
}

static ERL_NIF_TERM taproot_tweak_xonly_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 2) return enif_make_badarg(env);
  ErlNifBinary pubkey_bin, tweak_bin;
  if (!bin(env, argv[0], &pubkey_bin) || !bin(env, argv[1], &tweak_bin)) {
    return enif_make_badarg(env);
  }
  if (pubkey_bin.size != 32 || tweak_bin.size != 32) {
    return make_error(env, "invalid taproot tweak input length");
  }

  secp256k1_xonly_pubkey internal;
  secp256k1_pubkey output;
  if (!secp256k1_xonly_pubkey_parse(CTX, &internal, pubkey_bin.data)) {
    return make_error(env, "invalid xonly pubkey");
  }
  if (!secp256k1_xonly_pubkey_tweak_add(CTX, &output, &internal, tweak_bin.data)) {
    return make_error(env, "taproot tweak failed");
  }

  secp256k1_xonly_pubkey output_xonly;
  int parity = 0;
  secp256k1_xonly_pubkey_from_pubkey(CTX, &output_xonly, &parity, &output);

  ERL_NIF_TERM out_bin;
  unsigned char *out = enif_make_new_binary(env, 32, &out_bin);
  secp256k1_xonly_pubkey_serialize(CTX, out, &output_xonly);
  return enif_make_tuple3(env, atom_ok, out_bin, enif_make_int(env, parity));
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)priv;
  (void)info;
  CTX = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
  if (CTX == NULL) return 1;
  atom_ok = enif_make_atom(env, "ok");
  atom_error = enif_make_atom(env, "error");
  return 0;
}

static void unload(ErlNifEnv *env, void *priv) {
  (void)env;
  (void)priv;
  if (CTX != NULL) {
    secp256k1_context_destroy(CTX);
    CTX = NULL;
  }
}

static ErlNifFunc funcs[] = {
  {"verify_der_signature", 3, verify_der_signature_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"verify_schnorr_signature", 3, verify_schnorr_signature_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"taproot_tweak_xonly", 2, taproot_tweak_xonly_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND}
};

ERL_NIF_INIT(exbitnode_native_secp256k1, funcs, load, NULL, NULL, unload)
