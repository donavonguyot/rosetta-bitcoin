"""CI checkout inventory preserves upstream provenance and detects later damage."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import snapshot_ci_source as snapshot
import verify_standalone as verifier


class SourceTest(unittest.TestCase):
    def test_inventory_uses_current_revision_without_rewriting_original_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            original = root / 'standalone-manifest.json'
            original.write_text('{"source_commit": "upstream"}\n')
            source = root / 'build.zig'
            source.write_text('current source\n')
            metadata = root / '.git'
            metadata.mkdir()
            (metadata / 'hook').symlink_to(source)
            def git(*args):
                if args == ('rev-parse', '--show-toplevel'):
                    return str(root)
                if args == ('rev-parse', 'HEAD'):
                    return 'b' * 40
                if args[0] == 'status':
                    return ''
                if args[0] == 'ls-files':
                    return 'build.zig\0standalone-manifest.json\0'
                raise AssertionError(args)
            with patch.object(snapshot, 'ROOT', root), patch.object(snapshot, 'git', git), \
                 patch.object(verifier, 'ROOT', root), contextlib.redirect_stdout(io.StringIO()):
                snapshot.main()
                inventory = root / '.zig-cache/ci-source-manifest.json'
                self.assertEqual(json.loads(inventory.read_text())['source_commit'], 'b' * 40)
                self.assertEqual(json.loads(original.read_text())['source_commit'], 'upstream')
                verifier.main(inventory)
                source.write_text('mutated\n')
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    verifier.main(inventory)


if __name__ == '__main__':
    unittest.main()
