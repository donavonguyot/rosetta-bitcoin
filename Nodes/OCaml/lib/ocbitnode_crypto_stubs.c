#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <secp256k1.h>
#include <secp256k1_extrakeys.h>
#include <secp256k1_schnorrsig.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  secp256k1_context *ctx;
} ocbitnode_verifier;

static void finalize_verifier(value v) {
  ocbitnode_verifier *wrapper = *(ocbitnode_verifier **)Data_custom_val(v);
  if (wrapper != NULL) {
    if (wrapper->ctx != NULL) {
      secp256k1_context_destroy(wrapper->ctx);
      wrapper->ctx = NULL;
    }
    free(wrapper);
  }
}

static struct custom_operations verifier_ops = {
  "rb.ocbitnode.secp256k1_verifier",
  finalize_verifier,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static ocbitnode_verifier *verifier_val(value v) {
  ocbitnode_verifier *wrapper = *(ocbitnode_verifier **)Data_custom_val(v);
  if (wrapper == NULL || wrapper->ctx == NULL) {
    caml_failwith("secp256k1 verifier is closed");
  }
  return wrapper;
}

static int ecdsa_verify_with_context(secp256k1_context *ctx, value pubkey_v, value msg_v, value sig_v) {
  int ok = 0;
  if (caml_string_length(msg_v) == 32) {
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
  }
  return ok;
}

static int schnorr_verify_with_context(secp256k1_context *ctx, value xonly_v, value msg_v, value sig_v) {
  int ok = 0;
  if (caml_string_length(xonly_v) == 32 && caml_string_length(msg_v) == 32 && caml_string_length(sig_v) == 64) {
    secp256k1_xonly_pubkey pubkey;
    if (secp256k1_xonly_pubkey_parse(ctx, &pubkey, (const unsigned char *)String_val(xonly_v))) {
      ok = secp256k1_schnorrsig_verify(ctx, (const unsigned char *)String_val(sig_v), (const unsigned char *)String_val(msg_v), 32, &pubkey);
    }
  }
  return ok;
}

static int schnorr_verify_message_with_context(secp256k1_context *ctx, value xonly_v, value msg_v, value sig_v) {
  int ok = 0;
  if (caml_string_length(xonly_v) == 32 && caml_string_length(sig_v) == 64) {
    secp256k1_xonly_pubkey pubkey;
    const unsigned char empty_msg = 0;
    const unsigned char *msg_ptr = caml_string_length(msg_v) == 0
      ? &empty_msg
      : (const unsigned char *)String_val(msg_v);
    if (secp256k1_xonly_pubkey_parse(ctx, &pubkey, (const unsigned char *)String_val(xonly_v))) {
      ok = secp256k1_schnorrsig_verify(ctx, (const unsigned char *)String_val(sig_v), msg_ptr, caml_string_length(msg_v), &pubkey);
    }
  }
  return ok;
}

static void taproot_tweak_compute(secp256k1_context *ctx, value xonly_v, value tweak_v, unsigned char output[32], int *parity_out) {
  if (caml_string_length(xonly_v) != 32 || caml_string_length(tweak_v) != 32) {
    caml_failwith("taproot tweak requires 32-byte xonly key and 32-byte tweak");
  }
  secp256k1_xonly_pubkey internal;
  secp256k1_pubkey output_pubkey;
  secp256k1_xonly_pubkey output_xonly;
  int parity = 0;
  if (!secp256k1_xonly_pubkey_parse(ctx, &internal, (const unsigned char *)String_val(xonly_v))) {
    caml_failwith("invalid xonly pubkey");
  }
  if (!secp256k1_xonly_pubkey_tweak_add(ctx, &output_pubkey, &internal, (const unsigned char *)String_val(tweak_v))) {
    caml_failwith("invalid taproot tweak");
  }
  if (!secp256k1_xonly_pubkey_from_pubkey(ctx, &output_xonly, &parity, &output_pubkey)) {
    caml_failwith("could not serialize tweaked xonly pubkey");
  }
  if (!secp256k1_xonly_pubkey_serialize(ctx, output, &output_xonly)) {
    caml_failwith("could not serialize tweaked xonly pubkey");
  }
  *parity_out = parity;
}

static value taproot_tweak_result(unsigned char output[32], int parity) {
  CAMLparam0();
  CAMLlocal2(out_string, tuple);
  out_string = caml_alloc_string(32);
  memcpy(Bytes_val(out_string), output, 32);
  tuple = caml_alloc_tuple(2);
  Store_field(tuple, 0, out_string);
  Store_field(tuple, 1, Val_int(parity));
  CAMLreturn(tuple);
}

CAMLprim value ocbitnode_verifier_create(value unit_v) {
  CAMLparam1(unit_v);
  CAMLlocal1(block);
  ocbitnode_verifier *wrapper = malloc(sizeof(ocbitnode_verifier));
  if (wrapper == NULL) caml_failwith("out of memory");
  wrapper->ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  if (wrapper->ctx == NULL) {
    free(wrapper);
    caml_failwith("could not create secp256k1 context");
  }
  block = caml_alloc_custom(&verifier_ops, sizeof(ocbitnode_verifier *), 0, 1);
  *((ocbitnode_verifier **)Data_custom_val(block)) = wrapper;
  CAMLreturn(block);
}

CAMLprim value ocbitnode_verifier_close(value verifier_v) {
  CAMLparam1(verifier_v);
  ocbitnode_verifier *wrapper = *(ocbitnode_verifier **)Data_custom_val(verifier_v);
  if (wrapper != NULL && wrapper->ctx != NULL) {
    secp256k1_context_destroy(wrapper->ctx);
    wrapper->ctx = NULL;
  }
  CAMLreturn(Val_unit);
}

CAMLprim value ocbitnode_verifier_context_mode(value verifier_v) {
  CAMLparam1(verifier_v);
  (void)verifier_val(verifier_v);
  CAMLreturn(caml_copy_string("libsecp256k1/reused_context_per_worker"));
}

CAMLprim value ocbitnode_ecdsa_verify_with_verifier_raw(value verifier_v, value pubkey_v, value msg_v, value sig_v) {
  CAMLparam4(verifier_v, pubkey_v, msg_v, sig_v);
  int ok = ecdsa_verify_with_context(verifier_val(verifier_v)->ctx, pubkey_v, msg_v, sig_v);
  CAMLreturn(Val_bool(ok));
}

CAMLprim value ocbitnode_schnorr_verify_with_verifier_raw(value verifier_v, value xonly_v, value msg_v, value sig_v) {
  CAMLparam4(verifier_v, xonly_v, msg_v, sig_v);
  int ok = schnorr_verify_with_context(verifier_val(verifier_v)->ctx, xonly_v, msg_v, sig_v);
  CAMLreturn(Val_bool(ok));
}

CAMLprim value ocbitnode_taproot_tweak_xonly_with_verifier(value verifier_v, value xonly_v, value tweak_v) {
  CAMLparam3(verifier_v, xonly_v, tweak_v);
  CAMLlocal1(result);
  unsigned char output[32];
  int parity = 0;
  taproot_tweak_compute(verifier_val(verifier_v)->ctx, xonly_v, tweak_v, output, &parity);
  result = taproot_tweak_result(output, parity);
  CAMLreturn(result);
}

CAMLprim value ocbitnode_ecdsa_verify_raw(value pubkey_v, value msg_v, value sig_v) {
  CAMLparam3(pubkey_v, msg_v, sig_v);
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  int ok = ctx != NULL ? ecdsa_verify_with_context(ctx, pubkey_v, msg_v, sig_v) : 0;
  if (ctx != NULL) secp256k1_context_destroy(ctx);
  CAMLreturn(Val_bool(ok));
}

CAMLprim value ocbitnode_schnorr_verify_raw(value xonly_v, value msg_v, value sig_v) {
  CAMLparam3(xonly_v, msg_v, sig_v);
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  int ok = ctx != NULL ? schnorr_verify_with_context(ctx, xonly_v, msg_v, sig_v) : 0;
  if (ctx != NULL) secp256k1_context_destroy(ctx);
  CAMLreturn(Val_bool(ok));
}

CAMLprim value ocbitnode_schnorr_verify_message_raw(value xonly_v, value msg_v, value sig_v) {
  CAMLparam3(xonly_v, msg_v, sig_v);
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  int ok = ctx != NULL ? schnorr_verify_message_with_context(ctx, xonly_v, msg_v, sig_v) : 0;
  if (ctx != NULL) secp256k1_context_destroy(ctx);
  CAMLreturn(Val_bool(ok));
}

CAMLprim value ocbitnode_taproot_tweak_xonly(value xonly_v, value tweak_v) {
  CAMLparam2(xonly_v, tweak_v);
  CAMLlocal1(result);
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  if (ctx == NULL) caml_failwith("could not create secp256k1 context");
  unsigned char output[32];
  int parity = 0;
  taproot_tweak_compute(ctx, xonly_v, tweak_v, output, &parity);
  result = taproot_tweak_result(output, parity);
  secp256k1_context_destroy(ctx);
  CAMLreturn(result);
}
