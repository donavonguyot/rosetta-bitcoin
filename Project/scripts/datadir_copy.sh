#!/bin/sh
# Clone a lab datadir, or delete old scratch clones whose task is already evidenced.
# Copies go through this script. Scratch is the default role.
# A seed or specimen copy must say why.
set -eu

LAB="${RB_STATE_ROOT:-$HOME/.rblab}/zig"
LOG="$LAB/datadirs.jsonl"
REPO=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
EVIDENCE="$REPO/Nodes/Shared/conformance/current_evidence.json"

role=scratch
task=
why=
sweep=

usage() {
  echo "usage: datadir_copy.sh [--role scratch|seed|live|specimen] [--task NAME] [--why TEXT] <src> <dst>" >&2
  echo "       datadir_copy.sh --sweep-scratch DAYS" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --role) role=$2; shift 2 ;;
    --task) task=$2; shift 2 ;;
    --why) why=$2; shift 2 ;;
    --sweep-scratch) sweep=$2; shift 2 ;;
    --) shift; break ;;
    -*) usage; exit 2 ;;
    *) break ;;
  esac
done

case "$role" in
  scratch|seed|live|specimen) ;;
  *) echo "role must be scratch, seed, live, or specimen" >&2; exit 2 ;;
esac

if [ -n "$sweep" ]; then
  python3 - "$sweep" "$LOG" "$EVIDENCE" "$LAB" <<'PY'
import json, shutil, sys, time
from pathlib import Path

days = float(sys.argv[1])
log = Path(sys.argv[2])
evidence_index = Path(sys.argv[3])
lab = Path(sys.argv[4])
protected = {
    "native-chainstate-100k",
    "stimulus-seed",
    "mempool-rung0",
    "trace-seed-155063",
    "triage-155447-native",
}
if not log.is_file():
    sys.exit(0)
index = json.loads(evidence_index.read_text())
haystacks = []
root = evidence_index.parents[3]
for entry in index.get("entries", []):
    rel = entry.get("path")
    if not rel:
        continue
    path = root / rel
    if path.is_file():
        haystacks.append(path.read_text(errors="replace"))
    haystacks.append(json.dumps(entry))
cutoff = time.time() - days * 86400
kept = []
for line in log.read_text().splitlines():
    if not line.strip():
        continue
    row = json.loads(line)
    created = row.get("created", "")
    try:
        stamp = time.strptime(created, "%Y-%m-%dT%H:%M:%SZ")
        age_ok = time.mktime(stamp) < cutoff
    except ValueError:
        age_ok = False
    task = row.get("task") or ""
    name = row.get("name") or ""
    target = lab / name
    referenced = bool(task) and any(task in text for text in haystacks)
    drop = (
        row.get("role") == "scratch"
        and age_ok
        and referenced
        and name not in protected
        and "toolchains" not in target.parts
        and target.is_dir()
    )
    if drop:
        shutil.rmtree(target)
        print(f"swept {target}")
        continue
    kept.append(line)
log.write_text(("\n".join(kept) + "\n") if kept else "")
PY
  exit 0
fi

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi

src=$1
dst=$2
if [ ! -d "$src" ] && [ -d "$LAB/$src" ]; then
  src="$LAB/$src"
fi
case "$dst" in
  /*) ;;
  *) dst="$LAB/$dst" ;;
esac

if [ ! -d "$src" ]; then
  echo "source datadir missing: $src" >&2
  exit 1
fi
if [ -e "$dst" ]; then
  echo "destination already exists: $dst" >&2
  exit 1
fi
case "$src" in
  */toolchains|*/toolchains/*) echo "refusing a toolchain path" >&2; exit 1 ;;
esac
case "$role" in
  seed|specimen)
    if [ -z "$why" ]; then
      echo "a $role copy must say why (--why)" >&2
      exit 1
    fi
    ;;
esac

parent=$(dirname "$dst")
mkdir -p "$parent"
src_dev=$(stat -f '%d' "$src")
dst_dev=$(stat -f '%d' "$parent")
src_vol=$(df "$src" | awk 'NR==2 { print $1 }')
if [ "$src_dev" = "$dst_dev" ] && mount | grep -F "$src_vol on " | grep -q '(apfs'; then
  clone=1
else
  clone=0
fi
free_pct=$(df -k "$parent" | awk 'NR==2 { printf "%.4f", ($4 / $2) * 100 }')
if [ "$clone" -eq 0 ]; then
  awk -v pct="$free_pct" 'BEGIN { if (pct + 0 <= 20) exit 1 }' || {
    echo "refusing a non-clone copy: ${free_pct}% free, need more than 20%" >&2
    exit 1
  }
fi

cp -Rc "$src" "$dst"

created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
name=$(basename "$dst")
cloned_from=$(basename "$src")
python3 - "$LOG" "$name" "$role" "$cloned_from" "$created" "$task" "$why" <<'PY'
import json, sys
from pathlib import Path
log, name, role, cloned_from, created, task, why = sys.argv[1:]
row = {
    "name": name,
    "role": role,
    "cloned_from": cloned_from,
    "created": created,
    "task": task,
}
if role in ("seed", "specimen"):
    row["why"] = why
path = Path(log)
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("a") as handle:
    handle.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
echo "$dst"
