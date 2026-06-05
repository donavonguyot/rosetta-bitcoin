#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <secp256k1.h>
#include <secp256k1_extrakeys.h>
#include <secp256k1_schnorrsig.h>
#include <string.h>

CAMLprim value ocbitnode_ecdsa_verify_raw(value pubkey_v, value msg_v, value sig_v) {
  CAMLparam3(pubkey_v, msg_v, sig_v);
  int ok = 0;
  if (caml_string_length(msg_v) == 32) {
    secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
    secp256k1_pubkey pubkey;
    secp256k1_ecdsa_signature sig;
    if (secp256k1_ec_pubkey_parse(ctx, &pubkey, (const unsigned char *)String_val(pubkey_v), caml_string_length(pubkey_v)) &&
        secp256k1_ecdsa_signature_parse_der(ctx, &sig, (const unsigned char *)String_val(sig_v), caml_string_length(sig_v))) {
      ok = secp256k1_ecdsa_verify(ctx, &sig, (const unsigned char *)String_val(msg_v), &pubkey);
      if (!ok) {
        secp256k1_ecdsa_signature normalized;
        secp256k1_ecdsa_signature_normalize(ctx, &normalized, &sig);
        ok = secp256k1_ecdsa_verify(ctx, &normalized, (const unsigned char *)String_val(msg_v), &pubkey);
      }
    }
    secp256k1_context_destroy(ctx);
  }
  CAMLreturn(Val_bool(ok));
}

CAMLprim value ocbitnode_schnorr_verify_raw(value xonly_v, value msg_v, value sig_v) {
  CAMLparam3(xonly_v, msg_v, sig_v);
  int ok = 0;
  if (caml_string_length(xonly_v) == 32 && caml_string_length(msg_v) == 32 && caml_string_length(sig_v) == 64) {
    secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
    secp256k1_xonly_pubkey pubkey;
    if (secp256k1_xonly_pubkey_parse(ctx, &pubkey, (const unsigned char *)String_val(xonly_v))) {
      ok = secp256k1_schnorrsig_verify(ctx, (const unsigned char *)String_val(sig_v), (const unsigned char *)String_val(msg_v), 32, &pubkey);
    }
    secp256k1_context_destroy(ctx);
  }
  CAMLreturn(Val_bool(ok));
}

CAMLprim value ocbitnode_taproot_tweak_xonly(value xonly_v, value tweak_v) {
  CAMLparam2(xonly_v, tweak_v);
  CAMLlocal3(result, out_string, tuple);
  if (caml_string_length(xonly_v) != 32 || caml_string_length(tweak_v) != 32) {
    caml_failwith("taproot tweak requires 32-byte xonly key and 32-byte tweak");
  }
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  secp256k1_xonly_pubkey internal;
  secp256k1_pubkey output_pubkey;
  secp256k1_xonly_pubkey output_xonly;
  unsigned char output[32];
  int parity = 0;
  if (!secp256k1_xonly_pubkey_parse(ctx, &internal, (const unsigned char *)String_val(xonly_v))) {
    secp256k1_context_destroy(ctx);
    caml_failwith("invalid xonly pubkey");
  }
  if (!secp256k1_xonly_pubkey_tweak_add(ctx, &output_pubkey, &internal, (const unsigned char *)String_val(tweak_v))) {
    secp256k1_context_destroy(ctx);
    caml_failwith("invalid taproot tweak");
  }
  if (!secp256k1_xonly_pubkey_from_pubkey(ctx, &output_xonly, &parity, &output_pubkey)) {
    secp256k1_context_destroy(ctx);
    caml_failwith("could not serialize tweaked xonly pubkey");
  }
  if (!secp256k1_xonly_pubkey_serialize(ctx, output, &output_xonly)) {
    secp256k1_context_destroy(ctx);
    caml_failwith("could not serialize tweaked xonly pubkey");
  }
  secp256k1_context_destroy(ctx);
  out_string = caml_alloc_string(32);
  memcpy(Bytes_val(out_string), output, 32);
  tuple = caml_alloc_tuple(2);
  Store_field(tuple, 0, out_string);
  Store_field(tuple, 1, Val_int(parity));
  result = tuple;
  CAMLreturn(result);
}
