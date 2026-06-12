#!/usr/bin/env python3
"""Run one read-only SQL query against Project/project.db."""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any
from urllib.parse import quote


READONLY_PREFIXES = ("select", "with")
SAFE_PRAGMAS = {
    "database_list",
    "foreign_key_list",
    "index_info",
    "index_list",
    "index_xinfo",
    "table_info",
    "table_list",
    "table_xinfo",
}
WRITE_ACTIONS = {
    sqlite3.SQLITE_ALTER_TABLE,
    sqlite3.SQLITE_ATTACH,
    sqlite3.SQLITE_CREATE_INDEX,
    sqlite3.SQLITE_CREATE_TABLE,
    sqlite3.SQLITE_CREATE_TEMP_INDEX,
    sqlite3.SQLITE_CREATE_TEMP_TABLE,
    sqlite3.SQLITE_CREATE_TEMP_TRIGGER,
    sqlite3.SQLITE_CREATE_TEMP_VIEW,
    sqlite3.SQLITE_CREATE_TRIGGER,
    sqlite3.SQLITE_CREATE_VIEW,
    sqlite3.SQLITE_DELETE,
    sqlite3.SQLITE_DETACH,
    sqlite3.SQLITE_DROP_INDEX,
    sqlite3.SQLITE_DROP_TABLE,
    sqlite3.SQLITE_DROP_TEMP_INDEX,
    sqlite3.SQLITE_DROP_TEMP_TABLE,
    sqlite3.SQLITE_DROP_TEMP_TRIGGER,
    sqlite3.SQLITE_DROP_TEMP_VIEW,
    sqlite3.SQLITE_DROP_TRIGGER,
    sqlite3.SQLITE_DROP_VIEW,
    sqlite3.SQLITE_INSERT,
    sqlite3.SQLITE_UPDATE,
}


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project mission-control DB path")
    parser.add_argument("--sql", required=True, help="Single read-only SQL statement to run")
    parser.add_argument("--json", action="store_true", help="Print result rows as JSON")
    return parser.parse_args()


def normalize_db_path(db_path: str) -> Path:
    path = Path(db_path)
    if not path.is_absolute():
        path = repo_root() / path
    return path


def strip_one_trailing_semicolon(sql: str) -> str:
    stripped = sql.strip()
    return stripped[:-1].strip() if stripped.endswith(";") else stripped


def validate_sql(sql: str) -> str:
    statement = strip_one_trailing_semicolon(sql)
    if not statement:
        raise ValueError("empty SQL is not allowed")
    if statement.startswith((".", "!")):
        raise ValueError("sqlite shell commands are not supported")
    if ";" in statement:
        raise ValueError("multiple SQL statements are not allowed")

    lowered = statement.lstrip().lower()
    if lowered.startswith(READONLY_PREFIXES):
        return statement

    pragma_match = re.match(r"pragma\s+([a-z_]+)\b", lowered)
    if pragma_match and pragma_match.group(1) in SAFE_PRAGMAS and "=" not in statement:
        return statement

    raise ValueError("only one read-only SELECT, WITH, or safe PRAGMA statement is allowed")


def connect_readonly(db_path: Path) -> sqlite3.Connection:
    uri = f"file:{quote(str(db_path.resolve()), safe='/')}?mode=ro"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only = ON")

    def authorize(action: int, _arg1: str | None, _arg2: str | None, _db: str | None, _source: str | None) -> int:
        if action in WRITE_ACTIONS:
            return sqlite3.SQLITE_DENY
        return sqlite3.SQLITE_OK

    connection.set_authorizer(authorize)
    return connection


def rows_as_dicts(rows: list[sqlite3.Row]) -> list[dict[str, Any]]:
    return [dict(row) for row in rows]


def print_table(rows: list[dict[str, Any]]) -> None:
    if not rows:
        print("(no rows)")
        return

    columns = list(rows[0].keys())
    widths = {
        column: max(len(column), *(len(str(row.get(column, ""))) for row in rows))
        for column in columns
    }
    header = "  ".join(column.ljust(widths[column]) for column in columns)
    divider = "  ".join("-" * widths[column] for column in columns)
    print(header)
    print(divider)
    for row in rows:
        print("  ".join(str(row.get(column, "")).ljust(widths[column]) for column in columns))


def main() -> int:
    args = parse_args()
    try:
        statement = validate_sql(args.sql)
        with connect_readonly(normalize_db_path(args.db)) as connection:
            cursor = connection.execute(statement)
            if cursor.description is None:
                raise ValueError("statement did not produce result rows")
            result_rows = rows_as_dicts(list(cursor))
    except (OSError, sqlite3.Error, ValueError) as exc:
        print(f"query_db: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(result_rows, indent=2, sort_keys=True))
    else:
        print_table(result_rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
