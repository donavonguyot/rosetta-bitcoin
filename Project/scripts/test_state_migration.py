import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import migrate_state as migration
from migrate_core import seed_hash
import state_root


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.source = self.repo / migration.SOURCES["campaigns"]
        self.source.mkdir(parents=True)
        (self.source / "evidence.json").write_text('{"preserve":true}')
        self.paths = state_root.state_paths(self.base / "state")
        self.paths["root"].mkdir()
        self.mock = patch.dict(state_root.PATHS, self.paths)
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def migrate(self, apply=True, **kwargs):
        return migration.migrate(self.repo, "campaigns", apply, idle=lambda _: None, floor=0, **kwargs)

    def test_dry_run_and_verified_idempotent_cutover(self):
        before = migration.inventory(self.source)
        self.assertEqual(self.migrate(False)["phase"], "planned")
        self.assertFalse(self.paths["campaigns"].exists())
        result = self.migrate()
        self.assertEqual(result["phase"], "complete")
        self.assertTrue(self.source.is_symlink())
        self.assertEqual(before, migration.inventory(self.paths["campaigns"]))
        self.assertEqual(before, migration.inventory(Path(result["backup"])))
        self.assertEqual(result, self.migrate())

    def test_interrupted_copy_retains_original(self):
        with patch.object(migration.shutil, "copytree", side_effect=OSError("interrupted")):
            with self.assertRaisesRegex(OSError, "interrupted"):
                self.migrate()
        self.assertTrue(self.source.is_dir())
        self.assertFalse(self.source.is_symlink())
        self.assertEqual(migration.recover("campaigns", True)["phase"], "rolled_back")

    def test_occupied_destination_and_writer(self):
        self.paths["campaigns"].mkdir()
        with self.assertRaisesRegex(ValueError, "occupied"):
            self.migrate()
        self.paths["campaigns"].rmdir()
        with self.assertRaisesRegex(RuntimeError, "writer"):
            migration.migrate(self.repo, "campaigns", True, idle=lambda _: (_ for _ in ()).throw(RuntimeError("writer")), floor=0)
        self.assertFalse(self.paths["campaigns"].exists())

    def test_corrupt_copy_does_not_switch(self):
        original = migration.shutil.copytree
        def corrupt(source, dest, **kwargs):
            original(source, dest, **kwargs)
            (dest / "evidence.json").write_text("corrupt")
        with patch.object(migration.shutil, "copytree", side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, "differ"):
                self.migrate()
        self.assertFalse(self.source.is_symlink())

    def test_recovery_after_original_renamed(self):
        original = migration.save
        def interrupted(path, value):
            original(path, value)
            if value.get("phase") == "source_retained":
                raise OSError("power loss")
        with patch.object(migration, "save", side_effect=interrupted):
            with self.assertRaisesRegex(OSError, "power loss"):
                self.migrate()
        result = migration.recover("campaigns")
        self.assertEqual(result["phase"], "complete")
        self.assertEqual((self.source / "evidence.json").read_text(), '{"preserve":true}')

    def test_seed_hash_stable_and_sensitive(self):
        first = seed_hash(self.source)
        (self.source / "evidence.json").chmod(0o600)
        self.assertEqual(first, seed_hash(self.source))
        (self.source / "evidence.json").write_text("changed")
        self.assertNotEqual(first, seed_hash(self.source))


if __name__ == "__main__":
    unittest.main()
