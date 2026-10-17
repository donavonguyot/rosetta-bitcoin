"""Import the active checkout even when its parent directory is named worktrees."""
from pathlib import Path
import tempfile
import unittest

from import_all import default_blocker_ledgers, iter_default_json_files


class ImportWorktreeTests(unittest.TestCase):
    def test_imports_active_worktree_but_excludes_nested_checkouts(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'worktrees' / 'active'
            results = root / 'Nodes/Shared/testing/results'
            results.mkdir(parents=True)
            artifact = results / 'zig.json'
            artifact.write_text('{}')
            self.assertEqual(iter_default_json_files(root, results, False), [artifact])
            nested = root / 'worktrees/other/Nodes/Shared/testing/results'
            nested.mkdir(parents=True)
            (nested / 'zig.json').write_text('{}')
            self.assertEqual(iter_default_json_files(root, nested, False), [])
            ledger = root / 'Nodes/Zig/docs/BLOCKER_LEDGER.md'
            ledger.parent.mkdir(parents=True)
            ledger.write_text('ledger')
            self.assertEqual(default_blocker_ledgers(root), [ledger])


if __name__ == '__main__':
    unittest.main()
