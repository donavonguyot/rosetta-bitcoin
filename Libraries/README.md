# Reusable verification libraries

These packages are owned by the root repository but build independently of it.
They never import node or Project internals. Each package carries its own MIT
license, public API documentation, fixtures and external-consumer example.

- Go/libsecp256k1-go: own_curve, Go math/big and crypto/sha256.
- Zig/libsecp256k1-zig: own_curve, package-owned widened-integer arithmetic and
  standard-library SHA-256.

Both are experimental, variable-time verification implementations. There are no
secret-key operations or side-channel-resistance claims. Names do not imply
endorsement by the upstream bitcoin-core/libsecp256k1 project.

Crypto lanes are independent dependency categories; see
../Docs/native-crypto-contract.md. Ecosystem curves and C bindings are eligible
in their own lanes and need not become own_curve implementations.
