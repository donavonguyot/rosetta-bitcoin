"""Owner-scheduled Core cutover. Merely resolving paths never invokes this command."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import fcntl
import os

from build_fixture_package import write_tar
import migrate_state
from state_root import PATHS, primary_root, journal, mkdir


class HashStream:
    def __init__(self):
        self.hash = hashlib.sha256()

    def write(self, data):
        self.hash.update(data)
        return len(data)


def seed_hash(root: Path) -> str:
    files = []
    for path in root.rglob("*"):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError("Core seed contains unsupported filesystem entries")
        if path.is_file():
            files.append(path)
    output = HashStream()
    write_tar(root, files, output)
    return output.hash.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute-scheduled", action="store_true", required=True)
    parser.add_argument("--container", default="rosetta-bitcoin-core-testnet4")
    parser.add_argument("--repo", type=Path, default=primary_root())
    args = parser.parse_args()
    mkdir(PATHS["root"])
    lock = (PATHS["root"] / "migration.lock").open("a")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    source = args.repo / "Nodes/Reference/bitcoin-core-testnet4"
    journal("stop_core", source, {"restart_original_container_after_rollback": args.container})
    subprocess.run(["docker", "stop", "--time", "120", args.container], check=True)
    running = subprocess.check_output(["docker", "inspect", args.container, "--format", "{{.State.Running}}"], text=True).strip()
    if running != "false":
        raise RuntimeError("Core has not stopped")
    migrate_state.assert_idle(source)
    before = seed_hash(source)
    migrate_state.SOURCES["core"] = "Nodes/Reference/bitcoin-core-testnet4"
    result = migrate_state.migrate(args.repo, "core", True)
    after = seed_hash(PATHS["core"])
    result.update(seed_before=before, seed_after=after, seed_format="rb.canonical_tar.v1")
    migrate_state.save(PATHS["root"] / "migrations/core.json", result)
    if before != after:
        migrate_state.recover("core", rollback=True)
        raise RuntimeError("stopped-Core seed mismatch; destination will not start")
    env = dict(os.environ, RB_REFERENCE_DATADIR=str(PATHS["core"]))
    subprocess.run(["docker", "compose", "-f", "Nodes/Reference/docker/docker-compose.yml", "up", "-d"], cwd=args.repo, env=env, check=True)
    public = {"schema": "rb.core_seed_migration.v1", "date": result["date"], "seed_before": before,
              "seed_after": after, "canonicalization": "rb.canonical_tar.v1", "destination": "state:core/"}
    receipt = args.repo / "Nodes/Shared/conformance" / ("core_seed_migration_" + result["date"] + ".json")
    from build_fixture_package import publish
    publish(receipt, (json.dumps(public, indent=2, sort_keys=True) + "\n").encode())
    with (args.repo / "Nodes/Reference/README.md").open("a") as note:
        note.write(f"\n### Core state migration {result['date']}\n\nStopped-Core canonical-tar SHA-256 before: `{before}`; after: `{after}`. Receipt: `{receipt.name}`.\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
