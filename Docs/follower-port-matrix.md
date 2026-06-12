# Follower Blocker Matrix Projection

The follower blocker matrix is generated from Project mission-control data. The
matrix combines imported blocker ledgers, latest imported status snapshots, and
conformance fixture results. It is not maintained by editing this Markdown file.

## Query The Matrix

```bash
python3 Project/scripts/report.py --db Project/project.db --section blocker-matrix
```

For row-oriented SQL:

```bash
python3 Project/scripts/query_db.py \
  --sql "select * from follower_blocker_matrix order by height, port"
```

## Status Meanings

- `cleared`: the latest imported port status validates beyond the blocker
  height.
- `fixture_passed`: a port-specific conformance fixture for that blocker height
  passed, but live validation beyond that height is not implied.
- `blocked`: the port has an imported open blocker row at that height.
- `not_reached`: Project has imported status for the port, and that status is
  below the blocker height.
- `unknown`: Project does not have enough imported evidence to classify the
  port at that height.

## Update Rule

When a port clears a blocker, add or identify the port-local fixture/evidence,
record exact blocker facts in the port ledger, import Project, and query the
matrix again. Do not hand-edit matrix cells.
