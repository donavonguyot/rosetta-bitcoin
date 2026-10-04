import json
import sqlite3
import unittest

import import_all
from build_fixture_package import ROOT
from migrate_artifact_provenance import migrate


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.addCleanup(self.db.close)
        import_all.init_db(self.db, ROOT / "Project/schema.sql")

    def add(self, name, payload):
        self.db.execute("INSERT INTO artifacts(artifact_id,path,kind,source_sha256,summary_json,raw_json) VALUES(?,?, 'test', 'digest', ?, ?)", (name,name,json.dumps({"keep":"existing metadata"}),json.dumps(payload)))
        self.db.commit()

    def test_absent_metadata_view_and_idempotency(self):
        self.add("old", {})
        self.assertEqual(migrate(self.db)["updated_summaries"], 1)
        self.assertEqual(migrate(self.db)["updated_summaries"], 0)
        row = self.db.execute("SELECT summary_json FROM artifacts").fetchone()
        self.assertEqual(json.loads(row[0]), {"keep":"existing metadata","provenance_status":"absent"})
        self.assertEqual(self.db.execute("SELECT provenance_status FROM artifact_provenance").fetchone()[0], "absent")

    def test_bad_pin_refuses_before_any_summary_or_view_write(self):
        self.add("old", {})
        self.add("bad", {"provenance":None})
        before = self.db.total_changes
        with self.assertRaises(ValueError):
            migrate(self.db)
        self.assertEqual(self.db.total_changes, before)
        self.assertIsNone(self.db.execute("SELECT name FROM sqlite_master WHERE name='artifact_provenance'").fetchone())


if __name__ == "__main__":
    unittest.main()
