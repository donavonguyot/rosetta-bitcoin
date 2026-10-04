"""Add provenance metadata and its SQL projection to an existing Project database.

No table columns change. Validate all stored payloads before writing anything;
then replace only importer-owned provenance summary fields and the view.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sqlite3

from provenance import PROJECTION_SQL, validate

FIELDS = ("provenance", "provenance_status", "provenance_by_port")


def counts(connection: sqlite3.Connection) -> dict:
    groups = connection.execute("""SELECT
        coalesce(json_extract(summary_json, '$.provenance_status'), 'unmarked'), count(*)
        FROM artifacts GROUP BY 1 ORDER BY 1""").fetchall()
    return {"artifacts": sum(n for _, n in groups), "provenance_status": dict(groups)}


def migrate(connection: sqlite3.Connection) -> dict:
    before = counts(connection)
    updates = []
    for artifact_id, raw, summary in connection.execute("SELECT artifact_id, raw_json, summary_json FROM artifacts"):
        payload = json.loads(raw) if raw else {}
        if not isinstance(payload, dict):
            raise ValueError(f"artifact {artifact_id} payload must be an object")
        pins = validate(payload)
        previous = json.loads(summary or "{}")
        refreshed = {k: v for k, v in previous.items() if k not in FIELDS}
        refreshed.update(pins)
        if refreshed != previous:
            updates.append((json.dumps(refreshed, sort_keys=True, indent=2), artifact_id))
    # All retained-package validation above precedes migration writes.
    with connection:
        connection.execute("DROP VIEW IF EXISTS artifact_provenance")
        connection.execute(PROJECTION_SQL)
        connection.executemany("UPDATE artifacts SET summary_json=? WHERE artifact_id=?", updates)
        connection.execute("INSERT INTO meta(key,value) VALUES('migration.artifact_provenance','1') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
    return {"before": before, "after": counts(connection), "updated_summaries": len(updates), "added_columns": []}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=Path("Project/project.db"))
    args = parser.parse_args()
    if not args.db.is_file():
        parser.error("migration requires an existing Project database")
    with sqlite3.connect(args.db) as connection:
        print(json.dumps(migrate(connection), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
