from __future__ import annotations

from pybitnode.db.tracker import SCHEMA_VERSION


def init_schema(_db: object) -> None:
    """Compatibility shim for legacy imports.

    Python native mode stores schema metadata in RocksDB during tracker
    bootstrap. There is no SQLite schema initializer in the forward path.
    """


def seed_wire_capabilities(_db: object) -> None:
    """Compatibility shim; native tracker seeds wire capabilities directly."""
