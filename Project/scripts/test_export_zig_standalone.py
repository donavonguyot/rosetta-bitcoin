"""The exported node has immutable inputs and no implicit workspace links."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import export_zig_standalone as exporter


class StandaloneExportTest(unittest.TestCase):
    def test_materializes_only_declared_source_and_detects_damage(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve() / "workspace"
            port = root / exporter.PORT
            lib = root / exporter.CRYPTO
            port.mkdir(parents=True)
            lib.mkdir(parents=True)
            (port / "build.zig").write_text("node source\n")
            (lib / "build.zig").write_text("crypto source\n")
            (port / "libsecp256k1-zig").symlink_to(lib, target_is_directory=True)
            fixture = root / exporter.SHARED / "fixtures/mining/assembly_bytes_v1.bin"
            fixture.parent.mkdir(parents=True)
            fixture.write_bytes(b"frozen")
            (port / "zig-out").mkdir()
            (port / "zig-out/ignored").write_text("build output")
            workflow = root / exporter.WORKFLOW
            workflow.parent.mkdir(parents=True)
            workflow.write_text("name: Standalone CI\n")
            names = [str(exporter.WORKFLOW), str(exporter.PORT / "build.zig"), str(exporter.PORT / "libsecp256k1-zig"),
                     str(exporter.CRYPTO / "build.zig"), str(fixture.relative_to(root))]

            def fake_git(*args):
                if args[0] == "ls-files":
                    return "\0".join(names) + "\0"
                if args[0] == "rev-parse":
                    return "a" * 40 + "\n"
                if args[0] == "status":
                    return ""
                raise AssertionError(args)

            destination = Path(temp).resolve() / "standalone"
            with patch.object(exporter, "ROOT", root), patch.object(exporter, "git", fake_git):
                exporter.export(destination)
                with self.assertRaises(FileExistsError):
                    exporter.export(destination)
                with self.assertRaises(ValueError):
                    exporter.export(root / "nested")
            leak = port / "leak"
            leak.symlink_to(fixture)
            names.append(str(exporter.PORT / "leak"))
            with patch.object(exporter, "ROOT", root), patch.object(exporter, "git", fake_git):
                with self.assertRaisesRegex(ValueError, "regular source file"):
                    exporter.export(Path(temp) / "bad-export")
            self.assertFalse((destination / ".git").exists())
            self.assertFalse((destination / "zig-out").exists())
            self.assertFalse((destination / "libsecp256k1-zig").is_symlink())
            self.assertEqual((destination / "libsecp256k1-zig/build.zig").read_text(), "crypto source\n")
            manifest = json.loads((destination / "standalone-manifest.json").read_text())
            self.assertEqual(len(manifest["files"]), 4)
            self.assertEqual((destination / exporter.WORKFLOW).read_text(), "name: Standalone CI\n")
            verifier_path = exporter.ROOT / exporter.PORT / "scripts/verify_standalone.py"
            spec = importlib.util.spec_from_file_location("verify_export", verifier_path)
            verifier = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(verifier)
            with patch.object(verifier, "ROOT", destination), contextlib.redirect_stdout(io.StringIO()):
                verifier.main()
                frozen = destination / "fixtures/fixtures/mining/assembly_bytes_v1.bin"
                frozen.write_bytes(b"wrong")
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    verifier.main()
                frozen.unlink()
                with self.assertRaises(FileNotFoundError):
                    verifier.main()
                frozen.symlink_to(fixture)
                with self.assertRaisesRegex(ValueError, "symlink"):
                    verifier.main()


if __name__ == "__main__":
    unittest.main()
