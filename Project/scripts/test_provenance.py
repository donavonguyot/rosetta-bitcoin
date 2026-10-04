import copy
import json
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import build_fixture_package as packages
import import_all as importer
import provenance


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = self.root / "packages"
        self.receipt = packages.build(store=self.store)
        self.pins = {"fixture_hash": self.receipt["fixture_hash"], "source_commit": "a" * 40,
                     "binary_sha256": "b" * 64, "run_ref": "  opaque|value\n$unchanged  "}
        self.mock = patch.dict(packages.PATHS, packages=self.store)
        self.mock.start()
        self.addCleanup(self.mock.stop)
        self.db = sqlite3.connect(":memory:")
        self.addCleanup(self.db.close)
        importer.init_db(self.db, packages.ROOT / "Project/schema.sql")

    def artifact(self, gate="baseline_5k", pins=True):
        source = next((packages.ROOT / "Nodes/Shared/conformance/results").glob(f"cpp_control_{gate}_benchmark_*.json"))
        value = json.loads(source.read_text())
        if pins:
            value["provenance"] = self.pins.copy()
        else:
            value.pop("provenance", None)
        path = self.root / source.name
        path.write_text(json.dumps(value))
        return path, value

    def test_existing_gates_absent_and_verified(self):
        for gate in ("baseline_5k", "shakedown_50k", "performance_100k"):
            path, value = self.artifact(gate, False)
            importer.import_json_artifact(self.db, self.root, path, value)
            summary = json.loads(self.db.execute("SELECT summary_json FROM artifacts WHERE path=?", (path.name,)).fetchone()[0])
            self.assertEqual(summary["provenance_status"], "absent")
            value["provenance"] = self.pins
            path.write_text(json.dumps(value))
            importer.import_json_artifact(self.db, self.root, path, value)
            settings = json.loads(self.db.execute("SELECT settings_json FROM benchmarks JOIN artifacts ON source_artifact_id=artifact_id WHERE path=?", (path.name,)).fetchone()[0])
            self.assertEqual(settings["provenance"]["run_ref"], self.pins["run_ref"])

    def test_unchanged_reimport_still_verifies(self):
        path, value = self.artifact()
        importer.import_json_artifact(self.db, self.root, path, value)
        package = packages.package_path(self.pins["fixture_hash"], self.store)
        package.write_bytes(b"corrupt")
        before = self.db.total_changes
        with self.assertRaisesRegex(ValueError, "mismatch"):
            importer.import_json_artifact(self.db, self.root, path, value)
        self.assertEqual(before, self.db.total_changes)

    def test_old_package_and_missing(self):
        shared = self.root / "Shared"
        for folder in packages.ROOTS:
            shutil.copytree(packages.ROOT / "Nodes/Shared" / folder, shared / folder)
        (shared / "testing/fixtures/new.txt").write_text("new")
        self.assertNotEqual(self.pins["fixture_hash"], packages.build(shared, self.store)["fixture_hash"])
        self.assertEqual(provenance.validate({"provenance": self.pins})["provenance_status"], "verified")
        packages.package_path(self.pins["fixture_hash"], self.store).unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            provenance.validate({"provenance": self.pins})

    def test_malformed_is_not_absent(self):
        for value in (None, {}, "legacy", {**self.pins, "run_ref": 1}, {**self.pins, "source_commit": "HEAD"}):
            with self.assertRaises(ValueError):
                provenance.validate({"provenance": value})
        self.assertEqual(provenance.validate({}), {"provenance_status": "absent"})

    def test_toolchain_sha256_is_optional_hex(self):
        digest = "c" * 64
        summary = provenance.validate({"provenance": {**self.pins, "toolchain_sha256": digest}})
        self.assertEqual(summary["provenance"]["toolchain_sha256"], digest)
        with self.assertRaisesRegex(ValueError, "toolchain_sha256"):
            provenance.validate({"provenance": {**self.pins, "toolchain_sha256": "0.16.0"}})
        pins = {"toolchain_sha256": digest}
        self.assertEqual(provenance.validate({"provenance": pins}), {"provenance_status": "toolchain", "provenance": pins})
        binary = self.root / "zig"
        binary.write_bytes(b"zig-bytes")
        self.assertEqual(provenance.toolchain_sha256(binary), packages.sha256(binary))

    def test_experimental_dispatch_validates_before_writes(self):
        path = self.root / "crypto.json"
        value = {"schema": "rb.crypto_lane_result.v1", "provenance": {**self.pins, "fixture_hash": "0" * 64}}
        path.write_text(json.dumps(value))
        before = self.db.total_changes
        with self.assertRaisesRegex(ValueError, "missing"):
            importer.import_json_artifact(self.db, self.root, path, value)
        self.assertEqual(before, self.db.total_changes)

    def test_parallel_per_port_verification_and_projection(self):
        path = self.root / "parallel.json"
        value = {"schema": "benchmark.parallel_experiment", "ports": [
            {"port": "cpp", "provenance": self.pins.copy()}, {"port": "java"}]}
        path.write_text(json.dumps(value))
        importer.import_json_artifact(self.db, self.root, path, value)
        rows = self.db.execute("SELECT port, provenance_status, run_ref FROM artifact_provenance ORDER BY port").fetchall()
        self.assertEqual(rows, [("cpp", "verified", self.pins["run_ref"]), ("java", "absent", None)])
        packages.package_path(self.pins["fixture_hash"], self.store).write_bytes(b"corrupt")
        before = self.db.total_changes
        with self.assertRaisesRegex(ValueError, "mismatch"):
            importer.import_json_artifact(self.db, self.root, path, value)
        self.assertEqual(before, self.db.total_changes)


if __name__ == "__main__":
    unittest.main()
