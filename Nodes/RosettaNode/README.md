# RosettaNode

An executable specification transfer experiment, **not a Bitcoin node**.
It covers transaction encoding, structured serialization, identifiers and byte
sizes. It does not validate scripts, signatures, values, blocks or consensus.
No port registration, lifecycle entry, storage backend or sync gate is added.

The source is literate Markdown in `spec/`. Literal extraction commits authored
LLVM IR under `generated/`; `tools/generate_support.py` produces only mechanical
context accessors. The C hosts exercise the IR and provide a pinned OpenSSL
SHA-256 primitive. The Python JSON/ABI adapter marshals objects; the IR owns byte
parsing, serialization and double-hash composition. The separate Python chain
checker has its own decoder and serializer.

## Run locally

From the repository root:

```sh
python3 Nodes/RosettaNode/tools/run_lab.py python3 tools/gate.py
python3 Nodes/RosettaNode/tools/run_lab.py python3 tools/build.py
python3 Nodes/RosettaNode/tools/run_lab.py python3 -m unittest discover -s tests
python3 Nodes/RosettaNode/tools/run_lab.py python3 tools/adversarial.py
python3 Nodes/RosettaNode/tools/run_lab.py python3 tools/variants.py
python3 Nodes/RosettaNode/tools/run_lab.py python3 tools/transaction_book.py
```

`run_lab.py` requires the immutable local image identity in `toolchain.json`.
`Dockerfile` documents preparation; rebuilding its apt dependencies is not a
bit-reproducible image build. Never substitute a moving tag silently. Review and
record changed toolchain identities explicitly. The recorded run targets Linux
AArch64, LLVM 18.1.3; it is not a cross-architecture qualification.

JSON-lines execution, after building:

```sh
printf '%s\n' '{"op":"decode_exact","bytes":"01000000000000000000","mode":"witness"}' | \
  docker run --rm -i --network none \
  -v "$PWD/Nodes/RosettaNode:/work" \
  "$(python3 -c 'import json; print(json.load(open("Nodes/RosettaNode/toolchain.json"))["image_id"])')" \
  python3 tools/protocol.py
```

The ordinary `run_lab.py` launcher does not forward stdin; use the explicit
interactive-pipe invocation above for the JSON-lines protocol.

## Evidence and reproduction

Compact evidence lives in `evidence/`. Logs, executables, rendered documents,
local chain exports, model workspaces and full attempt outputs live in ignored
`.local/`. Do not add any of these results to Project evidence or leaderboards.

The mandatory CompactSize gate passed before transaction work began. It includes
85 cases per execution variant, a canonicality mutation with unaffected
controls, a deliberate ASan heap fault, symbol/block reachability, a rendered
packet, and fresh-container reproduction. Alive2 is unavailable in the pinned
image: the bounded helper experiment records **unsupported**, not verified.

The transaction evaluator checks witness/zero-flags behavior, cursor and resource
precedence, structured input, field modifications and identifiers. A separate
chain checker verifies transaction Merkle roots and BIP141 commitments (last
matching output, zero coinbase witness leaf, exactly one 32-byte reserved item).
The chain family constrains valid parse/hash composition only.

To refresh a read-only Reference export and check already-staged Shared fixtures:

```sh
python3 Nodes/RosettaNode/tools/export_blocks.py
python3 Nodes/RosettaNode/tools/run_lab.py python3 tools/check_chain.py
python3 Nodes/RosettaNode/tools/reproduce.py
python3 Nodes/RosettaNode/tools/reproduce_transactions.py
```

Shared block fixtures are copied to `.local/blocks/shared/` before checking.
The Reference export contains blocks 0 through 5000 in `.local/blocks/reference/`;
it uses only read-only RPC calls. It never mounts or changes Reference state.
The observed Python port's first-match commitment behavior is recorded as a
comparison disagreement and is not changed here. The pinned btcd adapter is
under `comparisons/`, evaluator-only; its dependencies must never enter attempts.

Reproduction compares semantic result manifests and extracted document text,
excluding timing and PDF binary metadata. It uses fresh containers and copied
source trees on the same host. Visual review is a separate explicit check.

## Reconstruction protocol

`spec/interface.md` is the shared interface. The reconstruction packet adds
contract detail and independently justified examples; no IR or evaluator code.
`evidence/packet.json` inventories the information difference sentence by sentence.
Agents receive the Markdown reconstruction packet corresponding to the rendered
PDF content; this cohort tests semantic packet transfer, not PDF-reading quality.
The immutable cohort freeze records source/material hashes before any attempt.

`tools/cohort.py` starts fresh local Codex sessions using named filesystem
permissions, no inherited project documents/user configuration, disabled memory,
plugins, browser, apps, agent delegation and tool networking. Each reading phase
has 15 minutes and read-only materials; implementation has 60 minutes. Standard
Go tooling is prewarmed outside timing. Actual reading, implementation and usage
records are separate. Temperature, seed and monetary costs remain null when the
runner does not expose them.

Each attempt must pass denied-read/network probes and a standard-library Go
build. No candidate can read the repository, reference, evaluator, other
attempts or user Codex configuration. The model controller itself needs its
normal service connection; candidate tool traffic is denied. These restrictions
are tested, not inferred from an instruction to the model.

Initial sources freeze before evaluation. A separately recorded 30-minute repair
round receives bounded minimized counterexamples. Structured feedback uses the
smallest failing corpus case; global minimality is not claimed. Initial results
alone measure transfer. Family-level scores prevent chain counts or hundreds of
truncations from dominating the result. All attempts, including failures, remain
in the record; never overwrite or silently retry an attempt ID.

No result establishes superiority of authored IR, a complete Bitcoin
specification, or node readiness. Cross-language continuation is conditional on
the Go cohort and is never pooled across changed packet/evaluator versions.

## Results and retained attempts

`REPORT.md` presents the completed initial/repair comparisons and their limits.
The Go initial result is **observed improvement** in this cohort. All document
submissions passed all evaluated families; all controls passed valid-chain
composition but missed synthetic profile cases. Two controls shared a negative
amount bug, so their structured failures are correlated rather than independent
evidence of missing serialization. Counterexample-assisted repairs are separate.

The conditional Rust and Zig pairs use the same frozen packet and semantic
evaluator. Language overlays change only the target toolchain, source entrypoint
and standard-library restriction. They are exploratory pairs, not a language
ranking. Rust must supply JSON and SHA-256 without third-party crates; the
different standard libraries therefore affect authoring work.

Campaign orchestration (creates new attempts; never rerun an existing ID):

```sh
python3 Nodes/RosettaNode/tools/cohort.py initial <new-id> document
python3 Nodes/RosettaNode/tools/cohort.py initial <new-id> control
python3 Nodes/RosettaNode/tools/evaluate_attempt.py <frozen-id>
python3 Nodes/RosettaNode/tools/cohort.py repair <evaluated-id>
python3 Nodes/RosettaNode/tools/evaluate_attempt.py <evaluated-id> --phase repair
```

The recorded six-attempt cohort is D1/D2/D3 and C1/C2/C3. Its conditional pairs
are RD1/RC1 and ZD1/ZC1; `tools/cross_language.py` and
`tools/evaluate_cross.py` provide their language-only adaptation.
`tools/finish_cross.py` coordinates evaluation, optional repairs and reproduction
of that fixed cohort after all initial sources freeze. Pinned native toolchain
paths describe this host; another host requires reviewed identity/configuration
changes and a new campaign freeze, not silent substitution.

To rebuild the compact analysis and check completion:

```sh
python3 Nodes/RosettaNode/tools/analyze_cohort.py
python3 Nodes/RosettaNode/tools/report.py
python3 Nodes/RosettaNode/tools/run_lab.py python3 tools/transaction_book.py
python3 Nodes/RosettaNode/tools/reproduce_transactions.py
python3 Nodes/RosettaNode/tools/validate_artifacts.py
```

Visual review is tied to PDF file hashes. A rebuild may change PDF metadata;
render and review it again before refreshing `transaction-visual-review.json`.
The validator exits nonzero if any required evidence is missing or stale.
Candidate source/logs and raw block exports remain ignored and local; compact
manifests retain their hashes. Parent-agent usage and monetary cost are unknown;
candidate CLI usage and measured phase times are retained without price estimates.
