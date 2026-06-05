type result_value =
  | Valid
  | Consensus_invalid
  | Malformed_input
  | Backend_unavailable

let string_of_result = function
  | Valid -> "valid"
  | Consensus_invalid -> "consensus_invalid"
  | Malformed_input -> "malformed_input"
  | Backend_unavailable -> "backend_unavailable"

let result_of_bool = function
  | true -> Valid
  | false -> Consensus_invalid

external taproot_tweak_xonly_raw : string -> string -> string * int = "ocbitnode_taproot_tweak_xonly"
external ecdsa_verify_raw : string -> string -> string -> bool = "ocbitnode_ecdsa_verify_raw"
external schnorr_verify_raw : string -> string -> string -> bool = "ocbitnode_schnorr_verify_raw"

let buffer_of_bytes bytes =
  let len = String.length bytes in
  let buffer = Bigarray.Array1.create Bigarray.char Bigarray.c_layout len in
  String.iteri (fun i c -> buffer.{i} <- c) bytes;
  buffer

let bytes_of_buffer buffer =
  String.init (Bigarray.Array1.dim buffer) (fun i -> buffer.{i})

let context () = Secp256k1.Context.create [ Secp256k1.Context.Verify; Secp256k1.Context.Sign ]

let protect f =
  try f () with
  | Invalid_argument _ -> Malformed_input
  | Failure _ -> Malformed_input
  | _ -> Backend_unavailable

let ecdsa_verify ~pubkey_hex ~msg_hash_hex ~signature_hex =
  protect (fun () ->
    let ctx = context () in
    let pubkey = Secp256k1.Key.read_pk_exn ctx (buffer_of_bytes (Util.bytes_of_hex pubkey_hex)) in
    let msg = Secp256k1.Sign.msg_of_bytes_exn (buffer_of_bytes (Util.bytes_of_hex msg_hash_hex)) in
    let signature = Secp256k1.Sign.read_der_exn ctx (buffer_of_bytes (Util.bytes_of_hex signature_hex)) in
    result_of_bool (Secp256k1.Sign.verify_exn ctx ~pk:pubkey ~msg ~signature))

let schnorr_verify ~xonly_pubkey_hex ~msg_hash_hex ~signature_hex =
  protect (fun () ->
    let ctx = context () in
    let xonly = Secp256k1.XOPubkey.parse_exn ctx (buffer_of_bytes (Util.bytes_of_hex xonly_pubkey_hex)) in
    let msg = buffer_of_bytes (Util.bytes_of_hex msg_hash_hex) in
    let signature = Secp256k1.Schnorr.of_bytes (buffer_of_bytes (Util.bytes_of_hex signature_hex)) in
    result_of_bool (Secp256k1.Schnorr.verify ctx signature msg xonly))

let ecdsa_verify_bytes ~pubkey ~msg_hash ~signature_der =
  try ecdsa_verify_raw pubkey msg_hash signature_der with _ -> false

let schnorr_verify_bytes ~xonly_pubkey ~msg_hash ~signature =
  try schnorr_verify_raw xonly_pubkey msg_hash signature with _ -> false

let tagged_sha256 ~tag ~msg =
  let tag_hash = Util.sha256_raw tag in
  Util.sha256_raw (tag_hash ^ tag_hash ^ msg)

let taproot_tweak_xonly ~xonly_pubkey_hex ~merkle_root_hex =
  try
    let xonly = Util.bytes_of_hex xonly_pubkey_hex in
    if String.length xonly <> 32 then Malformed_input, "", 0
    else
      let merkle_root = Util.bytes_of_hex merkle_root_hex in
      let tweak = tagged_sha256 ~tag:"TapTweak" ~msg:(xonly ^ merkle_root) in
      let tweaked, parity = taproot_tweak_xonly_raw xonly tweak in
      let _roundtrip =
        let ctx = context () in
        Secp256k1.XOPubkey.serialize_exn ctx (Secp256k1.XOPubkey.parse_exn ctx (buffer_of_bytes tweaked))
      in
      Valid, Util.hex_of_bytes tweaked, parity
  with
  | Invalid_argument _ | Failure _ -> Malformed_input, "", 0
  | _ -> Backend_unavailable, "", 0

let taproot_tweak_xonly_bytes ~xonly_pubkey ~merkle_root =
  try
    if String.length xonly_pubkey <> 32 then None
    else
      let tweak = tagged_sha256 ~tag:"TapTweak" ~msg:(xonly_pubkey ^ merkle_root) in
      Some (taproot_tweak_xonly_raw xonly_pubkey tweak)
  with _ -> None

let taproot_tweak_check ~xonly_pubkey_hex ~merkle_root_hex ~expected_output_xonly_hex ~expected_parity =
  match taproot_tweak_xonly ~xonly_pubkey_hex ~merkle_root_hex with
  | Valid, output, parity ->
      if output = String.lowercase_ascii expected_output_xonly_hex && parity = expected_parity then Valid
      else Consensus_invalid
  | observed, _, _ -> observed

let xonly_parse_serialize_hex xonly_pubkey_hex =
  try
    let ctx = context () in
    let parsed = Secp256k1.XOPubkey.parse_exn ctx (buffer_of_bytes (Util.bytes_of_hex xonly_pubkey_hex)) in
    Util.hex_of_bytes (bytes_of_buffer (Secp256k1.XOPubkey.serialize_exn ctx parsed))
  with _ -> ""
