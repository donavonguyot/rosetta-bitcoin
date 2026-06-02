from __future__ import annotations

import sqlite_utils

from pybitnode.db.schema import SCHEMA_VERSION, init_schema, seed_wire_capabilities
from pybitnode.wire.capabilities import (
    CAPABILITIES,
    CHECKPOINTS,
    checkpoint_status,
    full_node_wire_progress,
)


def test_capability_registry_is_binary():
    for cap in CAPABILITIES:
        assert isinstance(cap.implemented, bool)
        assert isinstance(cap.required, bool)


def test_checkpoint_pass_requires_all_required_capabilities():
    cap_map = {cap.id: 1 for cap in CAPABILITIES}
    statuses = checkpoint_status(cap_map)
    assert all(cp["required_pass"] for cp in statuses.values())


def test_wire_capabilities_table_seeded(tmp_path):
    db_path = tmp_path / "caps.db"
    db = sqlite_utils.Database(str(db_path))
    init_schema(db)
    assert db["wire_capabilities"].count == len(CAPABILITIES)
    rows = list(db["wire_capabilities"].rows_where("capability_id = ?", ["frame.build"], limit=1))
    assert rows[0]["implemented"] == 1
    meta = list(db["meta"].rows_where("key = ?", ["schema_version"], limit=1))[0]
    assert meta["value"] == str(SCHEMA_VERSION)
    db.close()


def test_full_node_wire_progress_counts(tmp_path):
    db_path = tmp_path / "progress.db"
    db = sqlite_utils.Database(str(db_path))
    init_schema(db)
    cap_map = {row["capability_id"]: int(row["implemented"]) for row in db["wire_capabilities"].rows}
    progress = full_node_wire_progress(cap_map)
    required = sum(1 for c in CAPABILITIES if c.required)
    assert progress["required_total"] == required
    assert progress["checkpoints_total"] == len(CHECKPOINTS)
    assert progress["required_done"] < required  # not complete yet
    db.close()


def test_seed_updates_registry_defaults(tmp_path):
    db_path = tmp_path / "reseed.db"
    db = sqlite_utils.Database(str(db_path))
    init_schema(db)
    row = list(db["wire_capabilities"].rows_where("capability_id = ?", ["frame.build"], limit=1))[0]
    db["wire_capabilities"].update(row["id"], {"implemented": 0})
    seed_wire_capabilities(db)
    row = list(db["wire_capabilities"].rows_where("capability_id = ?", ["frame.build"], limit=1))[0]
    assert row["implemented"] == 1
    db.close()
