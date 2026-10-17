# Zigibit agent guide

Read [README.md](README.md), [CONTRIBUTING.md](CONTRIBUTING.md),
[architecture](docs/ARCHITECTURE.md), and [blocker facts](docs/blocker_ledger.jsonl)
before changing the node. In the RB workspace, the root AGENTS.md also applies.

- Use Zig 0.16.0. Build, test, and generate docs with the commands in the README.
- Independently validate every connected block. Another node supplies bytes,
  never validity decisions. Stop on unsupported consensus rules and record the
  exact height, hash, transaction, input, missing rule, and reproducing fixture.
- Keep handshake height conservative and defer advanced negotiation until headers
  are current and the node is listening. Do not edit running sync code in place.
- Use one writer per datadir. Keep state outside source; never share a datadir
  with another process. Preserve failed proof state and evidence.
- Frozen fixtures and the crypto package are explicit vendored inputs. Follow
  [dependency provenance](docs/DEPENDENCIES.md) when updating them.
- Read [DOC_STANDARD.md](docs/DOC_STANDARD.md) before source documentation edits.
  Keep current readiness and benchmark claims out of architecture and comments.
- Run the relevant storage/crypto lanes after behavior changes. Do not turn a
  portability check, bounded sync, or clean restart into a tip or crash-safety claim.
- Do not add RB/Project runtime dependencies, absolute developer paths, or nested
  repositories. Lab orchestration and current imported evidence belong to RB.
