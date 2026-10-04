import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest

import build_fixture_package as pkg


class FixturePackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.shared = self.root / "Shared"
        shutil.copytree(pkg.ROOT / "Nodes/Shared/conformance/fixtures", self.shared / "conformance/fixtures")
        shutil.copytree(pkg.ROOT / "Nodes/Shared/testing/fixtures", self.shared / "testing/fixtures")
        self.store = self.root / "store"

    def test_reproducible_and_sensitive(self):
        first = pkg.build(self.shared, self.store)
        other = self.root / "other"
        shutil.copytree(self.shared, other)
        for p in pkg.fixture_files(other):
            os.utime(p, (42, 99))
            p.chmod(0o600)
        self.assertEqual(first, pkg.build(other, self.store))
        (other / "conformance/results").mkdir()
        (other / "conformance/results/unrelated.json").write_text("{}")
        self.assertEqual(first, pkg.build(other, self.store))
        (other / "testing/fixtures/extra.txt").write_text("changed")
        self.assertNotEqual(first["fixture_hash"], pkg.build(other, self.store)["fixture_hash"])
        pkg.verify(first["fixture_hash"], self.store)

    def test_corrupt_and_missing(self):
        digest = pkg.build(self.shared, self.store)["fixture_hash"]
        pkg.package_path(digest, self.store).write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "mismatch"):
            pkg.unpack(digest, self.root / "out", self.store)
        with self.assertRaisesRegex(ValueError, "missing"):
            pkg.verify("0" * 64, self.store)

    def test_symlink_source_rejected(self):
        (self.shared / "testing/fixtures/link").symlink_to("/etc/passwd")
        with self.assertRaisesRegex(ValueError, "unsupported"):
            pkg.build(self.shared, self.store)

    def test_unsafe_tar_rejected(self):
        self.store.mkdir()
        for name in ("../escape", "/absolute", "conformance/results/result.json"):
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode="w") as archive:
                info = tarfile.TarInfo(name)
                info.size = 1
                archive.addfile(info, io.BytesIO(b"x"))
            data = output.getvalue()
            digest = hashlib.sha256(data).hexdigest()
            pkg.package_path(digest, self.store).write_bytes(data)
            with self.assertRaisesRegex(ValueError, "unsafe"):
                pkg.unpack(digest, self.root / "out", self.store)


if __name__ == "__main__":
    unittest.main()
