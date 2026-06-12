# Script Fixture Structural Matrix

This file no longer tracks per-port pass/fail columns. Port results drift too
quickly for Markdown and are indexed by Project from compact conformance JSON.

Use Project for current imported script-corpus results:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/query_db.py \
  --sql "select port, result, result_count from conformance_summary where category = 'script_corpus' order by port, result"
```

Use `manifest.json` for structural fixture truth:

```bash
jq -r '.fixtures[] | [.fixture_id, .height, .template, .portability_status, (.groups | join(","))] | @tsv' \
  Nodes/Shared/conformance/fixtures/scripts/manifest.json
```

## Fields

| Field | Meaning |
|-------|---------|
| `fixture_id` | Stable cross-port fixture identifier. |
| `height` | Testnet4 block height for the spend. |
| `template` | Known spend/template classification when available. |
| `portability_status` | Fixture-byte readiness, not port implementation status. |
| `groups` | Search tags for related consensus rules. |

Historical harvest labels such as `missing_rule` are hints for triage. They are
not proof that a target port is missing that exact opcode or rule. Classify the
actual `ScriptError` first.
