# Docker Runtime Contract

Docker support is part of Core Node evidence, not a convenience wrapper. A port
that claims Core Node compliance must have a documented runtime surface, a clean
image build, a status command that runs inside the container, and proof/supervisor
commands that use explicit Docker volumes.

This contract prevents ports from rediscovering base-image, package, volume,
and peer-routing problems during blocker work.

## Required Manifest Fields

Every port must have a JSON manifest under `Nodes/Shared/docker/ports/` with
these declared surfaces:

```text
manifest_version
port
status
paths.root
paths.dockerfile
paths.compose
paths.dockerignore
images.base
images.runtime
images.os_family
images.package_manager
images.native_dependencies
volumes.data
volumes.proof
volumes.supervisor
commands
peer_modes
supervisor.stop_marker
supervisor.resume_marker
tick_json.required_fields
proof_artifacts
known_caveats
```

If a port does not have Docker support, its manifest status must say `missing`.
Silence is not acceptable. `PORT_DOCKER_INVENTORY.md` is now a projection guide;
current per-port rows come from manifests and Project views.

## Machine-Readable Manifests

Every port also has a JSON manifest under `Nodes/Shared/docker/ports/`:

```text
Nodes/Shared/docker/ports/<port>.docker.json
```

The manifest schema is [`docker_contract.schema.json`](docker_contract.schema.json).
It validates declarations under `Nodes/Shared/docker/ports/`. Docker proof result
JSON uses the separate conformance schema at
[`../conformance/docker_contract.schema.json`](../conformance/docker_contract.schema.json).
Validate all manifests with:

```bash
python3 Nodes/Shared/docker/validate_docker_contract.py
python3 Nodes/Shared/docker/validate_docker_contract.py --json
python3 Nodes/Shared/docker/validate_docker_contract.py --strict
```

The validator is report-only until the workspace deliberately ratchets Docker
compliance. A passing validator report means declarations are complete enough
to reason about; it does not run Docker builds by itself.

Default validation always exits `0` so agents can gather a full report. Strict
validation exits nonzero when manifest errors are present and treats nonstandard
Docker file layout as an error. Strict mode still does not require every runtime
proof command to pass; proof ratchets happen only after recorded proof runs.

## Standard Physical Layout

Every port with Docker support uses the same on-disk layout:

```text
Nodes/<Port>/docker/Dockerfile
Nodes/<Port>/docker/docker-compose.yml
Nodes/<Port>/docker/.dockerignore
```

If a compose file needs the port root as build context, use `context: ..` and
`dockerfile: docker/Dockerfile`. In that case, also keep a
`docker/Dockerfile.dockerignore` next to the Dockerfile so Docker applies the
same exclusions while using the port root as context.

Reference is a peer recipe rather than a port implementation, but it still uses
`Nodes/Reference/docker/docker-compose.yml` for layout consistency.

Python is not exempt from Docker parity. A forward Python native/Core claim
requires Docker proof and supervisor support against the RocksDB/native-crypto
runtime; historical compatibility daemons are not Core/native evidence.

## Standard Target Names

Ports should eventually expose these target names. Existing port-specific names
may remain during migration, but the manifest must map the contract command to
the current command.

Project imports the manifest command map into `Project/project.db` so operators
can compare run surfaces without reading every port directory:

```bash
python3 Project/scripts/report.py --db Project/project.db --section command-surface
sqlite-utils query Project/project.db \
  "select port, command_key, supported, command from port_command_surface order by port, command_key"
```

| Contract command | Meaning |
|------------------|---------|
| `docker-config` | Validate compose configuration. |
| `docker-build` | Build the proof/runtime image from a clean context. |
| `docker-warm` | Warm the campaign image/cache before benchmark or supervisor runs. |
| `docker-status` | Run status from inside the container/runtime surface. |
| `docker-proof-local` | Run bounded proof against local Reference peer. |
| `docker-probe-external` | Run bounded probe against actual network peer(s). |
| `docker-supervisor` | Start persistent Docker supervisor. |
| `docker-supervisor-status` | Read persistent supervisor status from inside Docker. |
| `docker-supervisor-stop` | Write the stop marker. |
| `docker-supervisor-resume` | Write the resume marker. |
| `docker-smoke-once` | One-shot supervisor loop smoke; no peer reachability required. |

Status and proof commands should follow the native naming contract: use
`status` for runtime/chainstate inspection, `storage-proof` for bounded storage
proofs, and `legacy-sqlite` for old evidence or fail-closed guards only.

Benchmark campaigns should use warm Docker runtimes and fresh proof state:
run `docker-warm` before the campaign, keep images/build cache until the
campaign checkpoint is complete, and reset only the proof volume for each fresh
gate run. Proof targets should not force an image rebuild by default; use
`DOCKER_REBUILD=1` when the operator intentionally wants a clean rebuild.

## Required Smoke Checks

A Docker-capable port must provide commands that prove:

```text
compose_config:
  docker compose config succeeds

clean_context_build:
  image builds from a context protected by .dockerignore
  generated host build trees, datadirs, DBs, logs, target trees, node_modules,
  and transient status files are excluded unless explicitly required

container_status:
  status command runs inside the container and reports the active backend

supervisor_tick:
  one-shot supervisor smoke emits AGENT_LOOP_TICK_chatreport

fresh_volume_proof:
  proof command uses a fresh proof volume separate from operational state

warm_image_reuse:
  proof and supervisor commands can reuse a previously built image unless
  DOCKER_REBUILD=1 is set

persistent_supervisor:
  long-running supervisor uses a persistent supervisor volume separate from
  fresh proof volumes
```

## Smoke Versus Network Proof

Supervisor smoke and network proof are different checks.

`supervisor_tick` passes when the container loop builds, starts, emits
`AGENT_LOOP_TICK_chatreport`, reads status from inside the runtime surface, and
honors stop/resume mechanics. It must not require a reachable peer.

Network proof is separate. It may require `host.docker.internal`, a Reference
container, explicit peer routing, and a healthy local Bitcoin Core testnet4 node.

## Volume Rules

Use separate volumes for separate purposes:

```text
data_volume:
  daemon/dev runtime state

proof_volume:
  fresh bounded proof state

supervisor_volume:
  persistent blocker-hunting state
```

Do not reuse a proof volume as a persistent blocker-hunting volume. Do not use
a host datadir for a Docker proof unless the proof explicitly documents why.

## Peer Modes

Docker peer strategy must be explicit and recorded as one of these modes:

```text
local_reference:
  deterministic proof surface
  peer = host.docker.internal:48333 or Reference compose service
  record peer, validated_height, header_height, stored_block_height, sync_status

external_manual:
  explicit external host:port
  record peer, disconnects, advertised start_height, validated_height,
  header_height, deferred handshake state

external_seed:
  DNS seed path
  record selected peer, seed source, disconnects, advertised start_height,
  validated_height, header_height, deferred handshake state
```

A proof must report which strategy it used. A Docker proof that silently falls
back to a different peer is not valid evidence.

## Supervisor Tick JSON

Every Docker supervisor must emit lines with the literal sentinel
`AGENT_LOOP_TICK_chatreport` followed by a JSON object containing:

```text
phase
runtime_surface
peer_mode
peer
validated_height
header_height
stored_block_height
sync_status
delta_since_last
process_running
current_blocker
```

Additional fields are allowed. Missing required fields make the supervisor
contract incomplete even if the node syncs.

## Base Image Rule

Ports may use language-native base images, but deviations must be inventoried.
The inventory must record OS family and package manager because build behavior
differs across Debian slim, Ubuntu, language runtime images, and vendor SDK
images.

When a port needs native libraries, the runtime image must install the matching
runtime packages. The build must not rely on host Homebrew, host SDKs, or local
build artifacts.

## Native/Core Storage Rule

Docker proof mode must obey the same native storage rules as host proof mode.
If native mode uses RocksDB, LevelDB, MDBX, or another KV store, Docker status,
sync, and proof commands must not instantiate SQLite for operational node truth.

See [`../storage/STORAGE_GATE.md`](../storage/STORAGE_GATE.md) and
[`../chainstate/CHAINSTATE_STORE.md`](../chainstate/CHAINSTATE_STORE.md).

## Compliance Result

A port's Docker runtime status is one of:

```text
missing
daemon_only
proof_partial
supervisor_partial
contract_passed
non_compliant
```

`contract_passed` requires all required smoke checks and an inventory row.
Consensus height progress does not imply Docker compliance.

Docker contract result artifacts use:

```text
Nodes/Shared/conformance/results/<port>_docker_contract_<date>.json
```

The result schema is
[`../conformance/docker_contract.schema.json`](../conformance/docker_contract.schema.json).

## Ratchet Order

Contract/tooling lands before implementation fixes. Ratchet ports in this order:

1. Java and C#, because they already have local proof and supervisor patterns.
2. Cpp after RocksDB owns every operational state family with no SQLite
   operational dependency.
3. Python and TypeScript as native proof/supervisor surfaces that still need
   empty-datadir replay before parity claims.
4. Elixir after its proof-partial Docker surface grows real native RocksDB/NIF
   and secp256k1 backends.

## Non-Goals For First Validator Pass

- Do not force all ports onto the same base image.
- Do not fix every port implementation while landing the contract.
- Do not treat Docker contract compliance as consensus or Core storage
  compliance.
- Do not run long syncs as part of manifest validation.
