# Port Docker Inventory

This inventory records each port's Docker runtime surface. It is intentionally
separate from consensus status: a port can clear a consensus blocker and still
be Docker/Core non-compliant.

Machine-readable manifests live under [`ports/`](ports/). Run the report-only
validator after manifest or Docker-surface changes:

```bash
python3 NodeCore/docker/validate_docker_contract.py
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
| Reference | `ports/reference.docker.json` | n/a | `Nodes/Reference/docker/docker-compose.yml` | `bitcoin/bitcoin:28.2` | daemon_only local peer service | report-only | n/a |
| Java | `ports/java.docker.json` | `Nodes/Java/docker/Dockerfile` | `Nodes/Java/docker/docker-compose.yml` | `eclipse-temurin:21-jdk` / `eclipse-temurin:21-jre` | supervisor_partial | report-only | RocksDB native evidence exists; keep verifying no legacy DB dependency in native mode |
| C# | `ports/csharp.docker.json` | `Nodes/CSharp/docker/Dockerfile` | `Nodes/CSharp/docker/docker-compose.yml` | `mcr.microsoft.com/dotnet/sdk:8.0` / `runtime:8.0` | supervisor_partial | report-only | RocksDB/native evidence exists; first-class blocker diagnostics still pending |
| Cpp | `ports/cpp.docker.json` | `Nodes/Cpp/docker/Dockerfile` | `Nodes/Cpp/docker/docker-compose.yml` | `ubuntu:24.04` / `ubuntu:24.04` | proof_partial | report-only | proof_pending: RocksDB-only native cutover landed; rerun Docker proof before promotion |
| Python | `ports/python.docker.json` | `Nodes/Python/docker/Dockerfile` | `Nodes/Python/docker/docker-compose.yml` | `python:3.12-slim` | daemon_only | report-only | SQLite-based by design; not a native Core storage claim |
| TypeScript | `ports/typescript.docker.json` | `Nodes/TypeScript/docker/Dockerfile` | `Nodes/TypeScript/docker/docker-compose.yml` | `node:20-slim` | daemon_only | report-only | SQLite-based by design; not a native Core storage claim |
| Elixir | `ports/elixir.docker.json` | missing | missing | missing | missing | report-only | no Docker/Core storage evidence |

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
known_caveats: Docker proof naming and native storage docs need cleanup
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
known_caveats: Cpp compliance backend is RocksDB-only; rerun proof after native cutover before promoting status
```

Cpp cannot claim Core Node compliance unless RocksDB owns headers, block index,
sync state, blocker state, status truth, UTXO, undo, metadata, and validated tip.
SQLite remains legacy/dev only and is not a Cpp compliance backend.

## Python

```text
dockerfile_path: Nodes/Python/docker/Dockerfile
compose_path: Nodes/Python/docker/docker-compose.yml
base_image: python:3.12-slim
runtime_image: python:3.12-slim
os_family: Debian slim
package_manager: apt plus pip
data_volume: pybitnode_data
proof_volume: missing
supervisor_volume: missing
status_command: python -m pybitnode.healthcheck
sync_or_proof_command: missing Docker proof target
supervisor_command: missing Docker supervisor target
peer_strategy: daemon compose publishes 48333; proof peer strategy not defined
dockerignore_status: present
runtime_surface_status: daemon_only
known_caveats: scout/reference implementation; SQLite-based by design
```

## TypeScript

```text
dockerfile_path: Nodes/TypeScript/docker/Dockerfile
compose_path: Nodes/TypeScript/docker/docker-compose.yml
base_image: node:20-slim
runtime_image: node:20-slim
os_family: Debian slim
package_manager: apt plus npm
data_volume: tsbitnode_data
proof_volume: missing
supervisor_volume: missing
status_command: node dist/cli/healthcheck.js
sync_or_proof_command: missing Docker proof target
supervisor_command: missing Docker supervisor target
peer_strategy: daemon compose publishes 48333; proof peer strategy not defined
dockerignore_status: present
runtime_surface_status: daemon_only
known_caveats: SQLite-based by design; existing host single-writer rules still apply
```

## Elixir

```text
dockerfile_path: missing
compose_path: missing
base_image: missing
runtime_image: missing
os_family: missing
package_manager: missing
data_volume: missing
proof_volume: missing
supervisor_volume: missing
status_command: host make node-status only
sync_or_proof_command: missing
supervisor_command: missing
peer_strategy: missing
dockerignore_status: missing
runtime_surface_status: missing
known_caveats: no Docker/Core storage evidence
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
