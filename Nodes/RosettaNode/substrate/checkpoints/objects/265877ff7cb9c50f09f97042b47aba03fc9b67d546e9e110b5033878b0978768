# RosettaNode reconstruction interface v1

Implement a Go JSON-lines program using the Go standard library only. Read one JSON object per line and write one response object per line. Do not use Bitcoin libraries, port sources, reference executables, evaluator dependencies, or network access.

Operations are decode_prefix(bytes, offset, mode, limits), decode_exact(bytes, mode, limits), serialize(transaction, include_witness, limits), and identify(transaction, limits). The request property selecting the operation is op. Modes are legacy and witness. include_witness is a JSON boolean. Byte strings use hexadecimal; integers use decimal strings. limits is an optional object with an optional max_items decimal string.

A transaction object has version_bits, inputs, outputs, and locktime. Each input has previous_txid_digest_order, previous_index, script, sequence, and witness. witness is an array of hexadecimal strings. Each output has amount and script.

Successful decode responses have status, transaction, and consumed. Successful serialize responses have status and bytes. Successful identify responses have status, stripped, full, stripped_size, full_size, txid_digest_order, txid_display_order, wtxid_digest_order, and wtxid_display_order.

The status enum is ok, invalid_request, malformed_encoding, resource_limit, execution_failure, transport_limit, or admission_limit. Error responses contain status only.

Request shape example (values illustrate JSON shape, with no supplied expected encoding):

```json
{"op":"serialize","transaction":{"version_bits":"1","inputs":[],"outputs":[],"locktime":"0"},"include_witness":false}
```

Serialize response shape: {"status":"ok","bytes":"<hexadecimal string>"}. Decode response shape: {"status":"ok","transaction":<transaction object>,"consumed":"<decimal string>"}.

Submit a directory containing main.go and any additional Go source files, with package main, buildable without external modules. Write diagnostics only to stderr. Initial submissions are frozen before evaluator feedback. You may finish before the deadline.
