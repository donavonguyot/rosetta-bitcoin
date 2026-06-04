#include <node_api.h>
#include <secp256k1.h>
#include <secp256k1_extrakeys.h>
#include <secp256k1_schnorrsig.h>

#include <cstring>

namespace {

thread_local secp256k1_context* tls_context = nullptr;

secp256k1_context* context() {
  if (tls_context == nullptr) {
    tls_context = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
  }
  return tls_context;
}

void close_context() {
  if (tls_context != nullptr) {
    secp256k1_context_destroy(tls_context);
    tls_context = nullptr;
  }
}

napi_value make_boolean(napi_env env, bool value) {
  napi_value result;
  napi_get_boolean(env, value, &result);
  return result;
}

napi_value make_null(napi_env env) {
  napi_value result;
  napi_get_null(env, &result);
  return result;
}

bool buffer_arg(napi_env env, napi_callback_info info, size_t index, void** data, size_t* length, size_t expected_argc) {
  size_t argc = expected_argc;
  napi_value args[3];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc <= index) {
    return false;
  }
  bool is_buffer = false;
  napi_is_buffer(env, args[index], &is_buffer);
  if (!is_buffer) {
    return false;
  }
  napi_get_buffer_info(env, args[index], data, length);
  return true;
}

napi_value verify_ecdsa_der(napi_env env, napi_callback_info info) {
  void* pubkey_data = nullptr;
  void* msg_data = nullptr;
  void* sig_data = nullptr;
  size_t pubkey_len = 0;
  size_t msg_len = 0;
  size_t sig_len = 0;
  if (!buffer_arg(env, info, 0, &pubkey_data, &pubkey_len, 3) ||
      !buffer_arg(env, info, 1, &msg_data, &msg_len, 3) ||
      !buffer_arg(env, info, 2, &sig_data, &sig_len, 3) ||
      msg_len != 32 || pubkey_len == 0 || sig_len == 0) {
    return make_boolean(env, false);
  }

  secp256k1_pubkey pubkey;
  secp256k1_ecdsa_signature signature;
  auto* ctx = context();
  if (ctx == nullptr ||
      secp256k1_ec_pubkey_parse(ctx, &pubkey, static_cast<const unsigned char*>(pubkey_data), pubkey_len) != 1 ||
      secp256k1_ecdsa_signature_parse_der(ctx, &signature, static_cast<const unsigned char*>(sig_data), sig_len) != 1) {
    return make_boolean(env, false);
  }
  const auto* msg32 = static_cast<const unsigned char*>(msg_data);
  if (secp256k1_ecdsa_verify(ctx, &signature, msg32, &pubkey) == 1) {
    return make_boolean(env, true);
  }
  secp256k1_ecdsa_signature normalized;
  if (secp256k1_ecdsa_signature_normalize(ctx, &normalized, &signature) != 1) {
    return make_boolean(env, false);
  }
  return make_boolean(env, secp256k1_ecdsa_verify(ctx, &normalized, msg32, &pubkey) == 1);
}

napi_value verify_schnorr(napi_env env, napi_callback_info info) {
  void* pubkey_data = nullptr;
  void* msg_data = nullptr;
  void* sig_data = nullptr;
  size_t pubkey_len = 0;
  size_t msg_len = 0;
  size_t sig_len = 0;
  if (!buffer_arg(env, info, 0, &pubkey_data, &pubkey_len, 3) ||
      !buffer_arg(env, info, 1, &msg_data, &msg_len, 3) ||
      !buffer_arg(env, info, 2, &sig_data, &sig_len, 3) ||
      pubkey_len != 32 || msg_len != 32 || sig_len != 64) {
    return make_boolean(env, false);
  }

  auto* ctx = context();
  secp256k1_xonly_pubkey pubkey;
  if (ctx == nullptr ||
      secp256k1_xonly_pubkey_parse(ctx, &pubkey, static_cast<const unsigned char*>(pubkey_data)) != 1) {
    return make_boolean(env, false);
  }
  return make_boolean(env, secp256k1_schnorrsig_verify(
    ctx,
    static_cast<const unsigned char*>(sig_data),
    static_cast<const unsigned char*>(msg_data),
    msg_len,
    &pubkey
  ) == 1);
}

napi_value taproot_tweak_xonly(napi_env env, napi_callback_info info) {
  void* pubkey_data = nullptr;
  void* tweak_data = nullptr;
  size_t pubkey_len = 0;
  size_t tweak_len = 0;
  if (!buffer_arg(env, info, 0, &pubkey_data, &pubkey_len, 2) ||
      !buffer_arg(env, info, 1, &tweak_data, &tweak_len, 2) ||
      pubkey_len != 32 || tweak_len != 32) {
    return make_null(env);
  }

  auto* ctx = context();
  secp256k1_xonly_pubkey internal;
  secp256k1_pubkey output;
  if (ctx == nullptr ||
      secp256k1_xonly_pubkey_parse(ctx, &internal, static_cast<const unsigned char*>(pubkey_data)) != 1 ||
      secp256k1_xonly_pubkey_tweak_add(ctx, &output, &internal, static_cast<const unsigned char*>(tweak_data)) != 1) {
    return make_null(env);
  }

  int parity = 0;
  secp256k1_xonly_pubkey output_xonly;
  unsigned char serialized[32];
  if (secp256k1_xonly_pubkey_from_pubkey(ctx, &output_xonly, &parity, &output) != 1 ||
      secp256k1_xonly_pubkey_serialize(ctx, serialized, &output_xonly) != 1) {
    return make_null(env);
  }

  napi_value result;
  napi_value parity_value;
  napi_value output_value;
  napi_create_object(env, &result);
  napi_create_int32(env, parity, &parity_value);
  napi_create_buffer_copy(env, sizeof(serialized), serialized, nullptr, &output_value);
  napi_set_named_property(env, result, "parity", parity_value);
  napi_set_named_property(env, result, "outputXonly", output_value);
  return result;
}

napi_value close_native_context(napi_env env, napi_callback_info) {
  close_context();
  return make_null(env);
}

napi_value init(napi_env env, napi_value exports) {
  napi_property_descriptor descriptors[] = {
    {"verifyEcdsaDer", nullptr, verify_ecdsa_der, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"verifySchnorr", nullptr, verify_schnorr, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"taprootTweakXonly", nullptr, taproot_tweak_xonly, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"closeContext", nullptr, close_native_context, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
  return exports;
}

}  // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
