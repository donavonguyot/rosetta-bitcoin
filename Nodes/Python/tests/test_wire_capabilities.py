from __future__ import annotations

from pybitnode.db.schema import SCHEMA_VERSION
from pybitnode.chainstate.tracker import ProjectTracker
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
    tracker = ProjectTracker(tmp_path / "chainstate-rocksdb")
    caps = tracker.list_wire_capabilities()
    assert len(caps) == len(CAPABILITIES)
    assert next(row for row in caps if row["capability_id"] == "frame.build")["implemented"] == 1
    assert tracker.get_meta("schema_version") == str(SCHEMA_VERSION)
    tracker.close()


def test_full_node_wire_progress_counts(tmp_path):
    tracker = ProjectTracker(tmp_path / "chainstate-rocksdb")
    cap_map = tracker.wire_capability_map()
    progress = full_node_wire_progress(cap_map)
    required = sum(1 for c in CAPABILITIES if c.required)
    assert progress["required_total"] == required
    assert progress["checkpoints_total"] == len(CHECKPOINTS)
    assert progress["required_done"] < required  # not complete yet
    tracker.close()


def test_seed_updates_registry_defaults(tmp_path):
    tracker = ProjectTracker(tmp_path / "chainstate-rocksdb")
    tracker.mark_wire_capability("frame.build", implemented=False)
    assert tracker.wire_capability_map()["frame.build"] == 0
    tracker.mark_wire_capability("frame.build", implemented=True, verified_by="code")
    assert tracker.wire_capability_map()["frame.build"] == 1
    tracker.close()
