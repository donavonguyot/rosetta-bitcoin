import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import migrate_state
import reclaim_state
import state_root


class ReclaimTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.paths = state_root.state_paths(Path(self.temp.name) / "state")
        self.paths["root"].mkdir()
        mock = patch.dict(state_root.PATHS, self.paths)
        mock.start()
        self.addCleanup(mock.stop)
        for key, relative in migrate_state.SOURCES.items():
            source = self.repo / relative
            source.mkdir(parents=True)
            (source / "evidence.json").write_text('{"preserve":true}')
            if key == "substrate":
                (source / "campaign-v2").mkdir()
                (source / "campaign-v2" / "evidence.json").write_text("frozen")
            migrate_state.migrate(self.repo, key, True, idle=lambda _: None, floor=0)
        self.receipt = self.paths["root"] / "migrations/reclaim.json"

    def run_reclaim(self, apply=False, idle=lambda _: None):
        return reclaim_state.reclaim(self.repo, self.receipt, apply, idle)

    def test_dry_run_and_unchanged_frozen_evidence(self):
        result = self.run_reclaim()
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["deleted"], [])
        self.assertTrue((self.paths["root"] / "retained-originals/campaigns").exists())
        self.assertTrue(result["classes"]["substrate"]["checks"]["frozen_campaign"])

    def test_changed_or_missing_destination_blocks_both_deletions(self):
        (self.paths["campaigns"] / "evidence.json").write_text("changed")
        (self.paths["substrate"] / "evidence.json").unlink()
        result = self.run_reclaim(True)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["deleted"], [])
        self.assertEqual(result["classes"]["campaigns"]["changed_destination_paths"], ["evidence.json"])
        self.assertEqual(result["classes"]["substrate"]["missing_destination_paths"], ["evidence.json"])

    def test_active_writer_blocks(self):
        def active(_):
            raise RuntimeError("state is in use by PID(s): 123")
        self.assertEqual(self.run_reclaim(True, active)["status"], "blocked")
        self.assertTrue((self.paths["root"] / "retained-originals/campaigns").exists())

    def test_only_authorized_originals_removed(self):
        protected = self.paths["root"] / "packages"
        protected.mkdir()
        (protected / "keep").write_text("protected")
        before = {key: migrate_state.inventory(self.paths[key]) for key in migrate_state.SOURCES}
        result = self.run_reclaim(True)
        self.assertEqual(result["status"], "complete")
        self.assertEqual(result["deleted"], ["campaigns", "substrate"])
        self.assertEqual((protected / "keep").read_text(), "protected")
        for key in migrate_state.SOURCES:
            self.assertEqual(migrate_state.inventory(self.paths[key]), before[key])
            self.assertFalse((self.paths["root"] / "retained-originals" / key).exists())
        with self.assertRaisesRegex(ValueError, "append-only"):
            self.run_reclaim(True)


if __name__ == "__main__":
    unittest.main()
