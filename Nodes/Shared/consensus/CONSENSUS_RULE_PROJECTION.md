# Consensus Rule Projection

File: `CONSENSUS_RULE_PROJECTION.md`

The consensus rule projection is a generated implementation map for port
authors. It joins the Shared consensus rule ledger with the Shared script
fixture manifest so an implementer can answer:

```text
Which fixtures exercise this rule, and what concrete script obligations do they
carry?
```

The projection is read-only and derived. It is not Bitcoin consensus authority,
not a port oracle, and not a readiness gate.

## Source Of Truth

The projection is generated only from current RosettaBitcoin Shared sources:

1. `Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json`
2. `Nodes/Shared/conformance/fixtures/scripts/manifest.json`

Historical IL material is not imported into the projection. Old IL remains
archive provenance. Any useful lesson from it must first be rewritten into a
RosettaBitcoin-owned doc, Shared fixture, Shared contract, or compact proof
artifact before it can affect current claims.

## Historical Provenance Vs Port Proof

Python and Java blocker history is preserved intentionally. That live-chain pain
is how many of the current rule cards and fixtures became visible, and the
projection should keep that origin clear rather than pretending the corpus was
invented in the abstract.

Historical fixes explain why a rule or fixture exists. They do not prove that
another port passes the rule. A port proves the obligation only with its own
current artifact, such as a `port.script_corpus_result.v1` result or another
Project-imported proof. Project remains the status and readiness surface.

## What It Contains

Each projected rule row includes:

- rule identity, category, chain, title, status, first observed facts, tags, and
  required rule labels from the rule ledger
- fixture IDs and joined fixture details: height, txid, input index, expected
  result, groups, template, missing-rule note, portability status, and required
  fixture files
- an evidence summary copied from the rule ledger
- explicit boundary fields: `authority=projection_only`,
  `source_of_truth=["rule_ledger","script_fixture_manifest"]`, and
  `does_not_prove=["port_pass","live_sync","benchmark_readiness","full_node_validity"]`
- SHA256 digests for the rule ledger and fixture manifest used to generate the
  projection

The projection can make implementation obligations easier to inspect. It does
not declare that any port passes a rule, reaches tip, satisfies a benchmark, or
acts as a full node.

## Generate And Validate

Run the generator self-test:

```bash
python3 Nodes/Shared/consensus/tools/build_consensus_rule_projection.py --self-test
```

Regenerate the projection artifact:

```bash
python3 Nodes/Shared/consensus/tools/build_consensus_rule_projection.py \
  --output Nodes/Shared/consensus/generated/consensus_rule_projection.json
```

The generator fails if a projected rule is not in the ledger, a referenced
fixture is not in the manifest, coverage no longer matches the current 45 rule
cards and 45 fixtures, or a projected status diverges from the rule ledger.

## Common Workflows

Start with the domain map when choosing a planning bundle:

```bash
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --list-domains
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --list-domains --markdown
```

Use exact queries when you already know a rule, fixture, tag, or height:

```bash
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --fixture scripts.p2tr_tapscript_133634
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --tag op_checksequenceverify
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --rule script.scripts_p2wsh_booland_136369
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --domain arithmetic --json
```

Turn a filtered result into a generic work bundle when a port needs an
implementation plan:

```bash
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --checklist --domain stack
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --checklist --domain relative-locktime --fixture scripts.p2wsh_rot_62754
```

Export Markdown when the bundle is meant for an issue, PR, or planning note:

```bash
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --checklist --domain tapscript --markdown
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --checklist --domain relative-locktime --fixture scripts.p2wsh_rot_62754 --markdown
```

Regenerate only after the Shared rule ledger or fixture manifest changes, then
run the generator self-test again.

## Query The Projection

Use the query helper to inspect the generated map without hand-reading the full
JSON artifact:

```bash
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --fixture scripts.p2tr_tapscript_133634
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --tag op_checksequenceverify
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --rule script.scripts_p2wsh_booland_136369
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --list-tags
```

Add `--json` for machine-readable filtered rows. Multiple filters are combined
as an intersection, so a query with both `--tag` and `--fixture` returns only
rules that match both.

Semantic domains are query-time navigation bundles for implementation planning.
They are not gates, profiles, or proof claims:

```bash
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --domain tapscript
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --domain arithmetic
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --domain relative-locktime
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --list-domains
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --list-domains --markdown
```

Domains match existing rule tags plus joined fixture groups and required rule
labels. A domain query can be combined with exact filters such as `--fixture`
or `--height` to narrow the result set. The Markdown domain index is a
stdout-only review surface for taxonomy balance; it is not a generated evidence
artifact or Project report.

Checklist mode turns any filtered projection result into a generic unchecked
implementation template. It is not a port progress report:

```bash
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --checklist --domain stack
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --checklist --domain tapscript
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --checklist --domain relative-locktime --fixture scripts.p2wsh_rot_62754
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --checklist --domain arithmetic --json
```

Checklist items are always unchecked because they are implementation prompts,
not evidence. A port still has to prove the work with its own
`port.script_corpus_result.v1` artifact.

Checklist output separates concrete implementation obligations from navigation
coverage:

- `Rule/Opcode Items` are closer to implementation work, such as opcodes,
  locktime, sighash, hash, multisig, signature, and altstack behavior.
- `Template/Semantic Coverage` labels describe the fixture family or planning
  scope, such as `p2tr`, `P2TR script-path`, `p2wsh`, `p2sh`, `tapscript`, or
  `bare_legacy`. They are useful coverage labels, but they are not always
  directly implementable rules.

When checklist mode uses `--domain`, output separates the selected domain's
declared core tags from the additional obligations carried by the matched
fixtures:

- `Domain-Core Items` explain the semantic bundle being requested.
- `Supporting Items` are companion fixture requirements, not port gaps.

Markdown export makes checklist output pasteable into issues, PRs, or port work
plans. It is not a generated evidence artifact or Project report:

```bash
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --checklist --domain stack --markdown
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --checklist --domain tapscript --markdown
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --checklist --domain relative-locktime --fixture scripts.p2wsh_rot_62754 --markdown
python3 Nodes/Shared/consensus/tools/query_consensus_rule_projection.py \
  --checklist --domain arithmetic --json
```

Markdown checklists compact large fixture file sets by default. They show key
file categories and summarize repeated witness files so work bundles remain
pasteable. Checklist JSON keeps the complete `required_fixture_files` array for
tooling and full audit detail.

The query helper preserves the projection boundary in its output:
`authority=projection_only` and
`does_not_prove=port_pass,live_sync,benchmark_readiness,full_node_validity`.
It is a lookup surface, not a new Project report or readiness gate.

## Domain Taxonomy Review

Domains are navigation aids for implementers. They are not gates, readiness
profiles, Project reports, or evidence claims. They intentionally overlap:
template domains such as `p2tr`, `p2wsh`, and `p2sh` can intersect with
semantic domains such as `stack`, `arithmetic`, `hash`, and
`relative-locktime`.

Domain counts describe the current 45-fixture projection shape. They do not
claim full Bitcoin consensus coverage.

| Domain | Current shape | Intended use | Caveat / follow-up |
|--------|---------------|--------------|--------------------|
| `stack` | 18 matched rules | Stress broad script-machine stack behavior. | Broad by design; many portability failures are exact stack semantics. |
| `p2tr` | 17 matched rules | Find the broader Taproot template family. | Keep distinct from `tapscript`, which is script-path execution. |
| `arithmetic` | 16 matched rules | Group numeric, boolean, and comparison opcode obligations. | Broad by design; exact numeric opcode semantics are a recurring portability risk. |
| `tapscript` | 15 matched rules | Focus on Taproot script-path execution obligations. | Overlaps with `p2tr`; this is intentional rather than duplicate status. |
| `p2wsh` | 13 matched rules | Find SegWit v0 witness-script obligations. | Often overlaps with stack, signature, locktime, and hash domains. |
| `p2sh` | 11 matched rules | Find legacy P2SH and wrapped-script obligations. | Template-oriented; not a legacy-consensus completeness claim. |
| `sighash` | 1 matched rule | Keep signature-hash edge cases visible. | Likely under-covered in the current corpus; this is a corpus-expansion clue, not a Project failure. |

A future template-family view may be useful, but this document does not add new
domains or change query behavior.

## How Ports Use It

Use the projection before implementing or debugging a known script rule:

1. Find the `rule_id` or fixture ID.
2. Read the joined fixture groups, template, required rules, files, and
   missing-rule note.
3. Implement the rule in the target port.
4. Prove the port with its own `port.script_corpus_result.v1` artifact.
5. Rebuild Project and use the consensus runway checks for current status.

The projection shortens archaeology. It does not replace port-owned proof.
