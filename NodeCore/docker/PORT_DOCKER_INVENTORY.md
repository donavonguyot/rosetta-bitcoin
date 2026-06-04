# Port Docker Inventory

This inventory records each port's Docker runtime surface. It is intentionally
separate from consensus status: a port can clear a consensus blocker and still
be Docker/Core non-compliant.

Machine-readable manifests live under [`ports/`](ports/). Run the report-only
or strict validator after manifest or Docker-surface changes:

```bash
python3 NodeCore/docker/validate_docker_contract.py
python3 NodeCore/docker/validate_docker_contract.py --strict
```

Docker proof result artifacts, when produced, belong in
`NodeCore/conformance/results/` using the retention rules in
[`../../docs/artifact-retention.md`](../../docs/artifact-retention.md). Do not
preserve Docker volumes or port-local proof datadirs as project evidence.

Status values come from
[`DOCKER_RUNTIME_CONTRACT.md`](DOCKER_RUNTIME_CONTRACT.md):

```text
missing
daemon_only
proof_partial
supervisor_partial
contract_passed
non_compliant
```

## Summary

| Port | Manifest | Dockerfile | Compose | Base / runtime image | Docker status | Validator status | Native/Core storage status |
|------|----------|------------|---------|----------------------|---------------|------------------|----------------------------|
| Reference | `ports/reference.docker.json` | n/a | `Nodes/Reference/docker/docker-compose.yml` | `bitcoin/bitcoin:28.2` | daemon_only local peer service | strict clean | n/a |
| Java | `ports/java.docker.json` | `Nodes/Java/docker/Dockerfile` | `Nodes/Java/docker/docker-compose.yml` | `eclipse-temurin:21-jdk` / `eclipse-temurin:21-jre` | supervisor_partial | strict clean; build/proof passed 2026-06-02 | RocksDB native evidence exists; keep verifying no legacy DB dependency in native mode |
| C# | `ports/csharp.docker.json` | `Nodes/CSharp/docker/Dockerfile` | `Nodes/CSharp/docker/docker-compose.yml` | `mcr.microsoft.com/dotnet/sdk:8.0` / `runtime:8.0` | supervisor_partial | strict clean; build/proof passed 2026-06-02 | RocksDB/native evidence exists; first-class blocker diagnostics still pending |
| Cpp | `ports/cpp.docker.json` | `Nodes/Cpp/docker/Dockerfile` | `Nodes/Cpp/docker/docker-compose.yml` | `ubuntu:24.04` / `ubuntu:24.04` | proof_partial | strict clean; build/proof passed 2026-06-02 | proof_partial: RocksDB-only operational store and proof artifact exist; staged live sync still pending |
| Python | `ports/python.docker.json` | `Nodes/Python/docker/Dockerfile` | `Nodes/Python/docker/docker-compose.yml` | `python:3.12-slim` | supervisor_partial | bounded native proof/supervisor declared; full replay pending | RocksDB/native-crypto path in progress; full replay/blocker rediscovery out of this plan |
| TypeScript | `ports/typescript.docker.json` | `Nodes/TypeScript/docker/Dockerfile` | `Nodes/TypeScript/docker/docker-compose.yml` | `node:20-slim` | supervisor_partial | strict clean before native proof update; rerun after TypeScript Docker native proof changes | RocksDB/native storage proof exists; Docker proof/supervisor targets added |
| Go | `ports/go.docker.json` | `Nodes/Go/docker/Dockerfile` | `Nodes/Go/docker/docker-compose.yml` | `golang:1.23-bookworm` / `debian:bookworm-slim` | proof_partial | strict clean; build/status/storage/script/local-reference proof passed 2026-06-03 | RocksDB storage proof and Docker local-reference replay through 10000 exist; native Go script corpus passes 45/45 |
| Rust | `ports/rust.docker.json` | `Nodes/Rust/docker/Dockerfile` | `Nodes/Rust/docker/docker-compose.yml` | `rust:1-bookworm` / `debian:bookworm-slim` | proof_partial | strict clean; build/status/storage/script/local-reference proof passed 2026-06-03 | RocksDB storage proof, native crypto vectors, Docker local-reference replay through 10000, and native Rust script corpus 45/45 exist |
| Elixir | `ports/elixir.docker.json` | `Nodes/Elixir/docker/Dockerfile` | `Nodes/Elixir/docker/docker-compose.yml` | `elixir:1.16-otp-26` | proof_partial | strict clean; build/status/proof/smoke passed 2026-06-02 | RocksDB native storage boundary/proof exists; native secp256k1 NIF still unavailable |

## Reference

```text
compose_path: Nodes/Reference/docker/docker-compose.yml
image: bitcoin/bitcoin:28.2
service: bitcoin-core-testnet4
container_name: rosetta-bitcoin-core-testnet4
ports: 127.0.0.1:48333, 127.0.0.1:48332
data_mount: Nodes/Reference/bitcoin-core-testnet4 -> /home/bitcoin/.bitcoin
healthcheck: bitcoin-cli -conf=/config/bitcoin.conf getblockchaininfo
status: daemon_only local peer service
```

The Reference node is not a follower implementation and does not satisfy any
port's validity proof. It is a local peer surface only.

## Java

```text
dockerfile_path: Nodes/Java/docker/Dockerfile
compose_path: Nodes/Java/docker/docker-compose.yml
base_image: eclipse-temurin:21-jdk
runtime_image: eclipse-temurin:21-jre
os_family: Debian-family Temurin image
package_manager: apt
data_volume: jbitnode_data
proof_volume: jbitnode_proof_data or DOCKER_PROOF_VOLUME
supervisor_volume: jbitnode_sync_data via Makefile
status_command: docker compose -f docker/docker-compose.yml run --rm --no-deps jbitnode-sync-proof com.jbitnode.cli.DbStatus
sync_or_proof_command: make docker-java-native-crypto-proof and related long-sync proofs
supervisor_command: make docker-java-sync-supervisor
stop_marker: .jbitnode_supervisor_stop
resume_marker: .jbitnode_supervisor_resume
peer_strategy: host.docker.internal:48333 with host-gateway mapping
dockerignore_status: present
runtime_surface_status: supervisor_partial
known_caveats: Tip-scale Docker proof remains separate from bounded proof pass
```

## CSharp

```text
dockerfile_path: Nodes/CSharp/docker/Dockerfile
compose_path: Nodes/CSharp/docker/docker-compose.yml
base_image: mcr.microsoft.com/dotnet/sdk:8.0
runtime_image: mcr.microsoft.com/dotnet/runtime:8.0
os_family: Debian-family Microsoft .NET image
package_manager: apt in image family
data_volume: not a daemon service in current compose
proof_volume: csbitnode_proof_data or DOCKER_PROOF_VOLUME
supervisor_volume: csbitnode_sync_data via Makefile
status_command: docker compose -f docker/docker-compose.yml run --rm --no-deps csbitnode-sync-proof status
sync_or_proof_command: make docker-csharp-native-crypto-proof
supervisor_command: make docker-csharp-sync-supervisor
stop_marker: .csbitnode_supervisor_stop
resume_marker: .csbitnode_supervisor_resume
peer_strategy: host.docker.internal:48333 by default
dockerignore_status: present
runtime_surface_status: supervisor_partial
known_caveats: blocker diagnostics at 22830 still need native first-class tooling
```

## Cpp

```text
dockerfile_path: Nodes/Cpp/docker/Dockerfile
compose_path: Nodes/Cpp/docker/docker-compose.yml
base_image: ubuntu:24.04
runtime_image: ubuntu:24.04
os_family: Ubuntu
package_manager: apt
native_dependencies: librocksdb-dev, libsecp256k1-dev
data_volume: cpbitnode_data
proof_volume: cpbitnode_proof_data
supervisor_volume: cpbitnode_sync_data
status_command: cpbitnode-db --datadir /data --chainstate-backend rocksdb
sync_or_proof_command: make docker-cpp-rocksdb-storage-proof
supervisor_command: make docker-cpp-sync-supervisor
stop_marker: .cpbitnode_supervisor_stop
resume_marker: .cpbitnode_supervisor_resume
peer_strategy: currently 127.0.0.1:48333 in compose; should be host.docker.internal or Reference service for Docker network proof
dockerignore_status: present after Cpp compliance attempt
runtime_surface_status: proof_partial
known_caveats: Cpp compliance backend is RocksDB-only; bounded storage proof passes with Codec v2 vectors; timed local Reference sync persisted through 28432 and shows RocksDB commit cost dominates; Docker network proof still needs host.docker.internal or Reference service before promotion
```

Cpp cannot claim Core Node compliance unless RocksDB owns headers, block index,
sync state, blocker state, status truth, UTXO, undo, metadata, and validated tip.
SQLite support has been removed from the Cpp port.

## Python

```text
dockerfile_path: Nodes/Python/docker/Dockerfile
compose_path: Nodes/Python/docker/docker-compose.yml
base_image: python:3.12-slim
runtime_image: python:3.12-slim
os_family: Debian slim
package_manager: apt plus pip
data_volume: pybitnode_data
proof_volume: pybitnode_proof_data
supervisor_volume: pybitnode_supervisor_data
status_command: python -m pybitnode.healthcheck
sync_or_proof_command: docker compose -f docker/docker-compose.yml run --rm --no-deps pybitnode-rocksdb-proof
supervisor_command: docker compose -f docker/docker-compose.yml up -d pybitnode-supervisor
peer_strategy: daemon compose publishes 48333; bounded proof does not use a peer
dockerignore_status: present
runtime_surface_status: supervisor_partial
known_caveats: bounded RocksDB/native-crypto proof and supervisor helpers only; full replay/blocker rediscovery remains a later plan
```

## TypeScript

```text
dockerfile_path: Nodes/TypeScript/docker/Dockerfile
compose_path: Nodes/TypeScript/docker/docker-compose.yml
base_image: node:20-slim
runtime_image: node:20-slim
os_family: Debian slim
package_manager: apt plus npm
native_dependencies: rocksdb npm native binding, secp256k1 npm native binding
data_volume: tsbitnode_data
proof_volume: tsbitnode_proof_data or DOCKER_PROOF_VOLUME
supervisor_volume: tsbitnode_sync_data or DOCKER_SYNC_VOLUME
status_command: make docker-typescript-sync-status
sync_or_proof_command: make docker-typescript-native-proof
supervisor_command: make docker-typescript-sync-supervisor
stop_marker: .tsbitnode_supervisor_stop
resume_marker: .tsbitnode_supervisor_resume
peer_strategy: host.docker.internal:48333 for local Reference proof metadata
dockerignore_status: present
runtime_surface_status: supervisor_partial
known_caveats: external network probe not standardized; native ECDSA is enabled, while Schnorr/Taproot still report pure TypeScript fallback pending a full native wrapper
```

## Go

```text
dockerfile_path: Nodes/Go/docker/Dockerfile
compose_path: Nodes/Go/docker/docker-compose.yml
base_image: golang:1.23-bookworm
runtime_image: debian:bookworm-slim
os_family: Debian
package_manager: apt plus go
native_dependencies: librocksdb-dev/librocksdb7.8, libsecp256k1-dev/libsecp256k1-1
data_volume: gobitnode_data
proof_volume: gobitnode_proof_data
supervisor_volume: gobitnode_sync_data
status_command: make docker-status
sync_or_proof_command: make docker-proof-local
supervisor_command: make docker-smoke-once
stop_marker: .gobitnode_supervisor_stop
resume_marker: .gobitnode_supervisor_resume
peer_strategy: host.docker.internal:48332 for local Reference RPC proof; no live P2P proof yet
dockerignore_status: present
runtime_surface_status: proof_partial
known_caveats: bounded local-reference RPC proof is not live P2P sync or tip maintenance; optimized replay now uses atomic RocksDB block commits, batch prevout loads, binary UTXO codec v2, and pipelined local-reference proof timing
```

## Rust

```text
dockerfile_path: Nodes/Rust/docker/Dockerfile
compose_path: Nodes/Rust/docker/docker-compose.yml
base_image: rust:1-bookworm
runtime_image: debian:bookworm-slim
os_family: Debian
package_manager: apt plus cargo
native_dependencies: librocksdb-dev/librocksdb7.8, rust-secp256k1
data_volume: rsbitnode_data
proof_volume: rsbitnode_proof_data
local_reference_volume: rsbitnode_local_reference_data
supervisor_volume: rsbitnode_sync_data
status_command: make docker-status
sync_or_proof_command: make docker-proof-local
supervisor_command: make docker-smoke-once
stop_marker: .rsbitnode_supervisor_stop
resume_marker: .rsbitnode_supervisor_resume
peer_strategy: local-reference RPC via host.docker.internal:48332; no live P2P proof yet
dockerignore_status: present
runtime_surface_status: proof_partial
known_caveats: bounded local-reference RPC proof is not live P2P sync or tip maintenance; binary gate remains not_attempted; live sync and tip maintenance remain follow-up work
```

## Elixir

```text
dockerfile_path: Nodes/Elixir/docker/Dockerfile
compose_path: Nodes/Elixir/docker/docker-compose.yml
base_image: elixir:1.16-otp-26
runtime_image: elixir:1.16-otp-26
os_family: Debian-family Elixir image
package_manager: apt plus mix
native_dependencies: librocksdb-dev/librocksdb7.8, libsecp256k1-dev/libsecp256k1-1
data_volume: exbitnode_data
proof_volume: exbitnode_proof_data
supervisor_volume: exbitnode_sync_data
status_command: make docker-status
sync_or_proof_command: make docker-proof-local
supervisor_command: make docker-supervisor
stop_marker: .exbitnode_supervisor_stop
resume_marker: .exbitnode_supervisor_resume
peer_strategy: host.docker.internal:48333 by default
dockerignore_status: present
runtime_surface_status: proof_partial
known_caveats: native secp256k1 backend boundary exists but NIF implementation is unavailable; external probe not standardized
```

## Follow-Up Checklist

Each port that wants Docker/Core compliance must provide:

```text
compose config command:
  documented and passing

clean image build:
  documented and passing from a .dockerignore-protected context

container status command:
  documented and reports runtime_surface=docker or supervisor

one-shot supervisor smoke:
  emits AGENT_LOOP_TICK_chatreport without requiring peer reachability

network proof:
  uses explicit host.docker.internal, Reference service, or external peer

fresh proof volume:
  separate from persistent supervisor volume

native storage proof:
  only for ports claiming Core storage compliance
```

Do not use this inventory as proof by itself. It is the checklist that tells
agents which proof commands still need to be run and recorded.

## Latest Validation Snapshot

2026-06-02 cleanup proof pass:

```text
validator_default: passed, errors=0, warnings=0
validator_strict: passed, errors=0, warnings=0
compose_config: passed for Cpp, CSharp, Elixir, Java, Python, Reference, TypeScript
docker_build: passed for Cpp, CSharp, Elixir, Java, Python, TypeScript
bounded_proof: passed for Cpp RocksDB storage proof, CSharp native Docker proof, Elixir RocksDB storage proof, Java native Docker proof
known_warning: TypeScript image build reports an npm audit vulnerability; build exit remains 0
not_promoted: no port was promoted to contract_passed; Elixir native secp256k1 NIF and long-running/tip-scale proofs remain separate
```
