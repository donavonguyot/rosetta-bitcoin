"""Documentation checks must inspect the active checkout, including a worktree."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import check_doc_drift as checker


class DocDriftTests(unittest.TestCase):
    def test_worktree_ancestors_do_not_exclude_active_sources(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'worktrees/active'
            docs = root / 'Docs'
            docs.mkdir(parents=True)
            current = docs / 'guide.md'
            current.write_text('[broken](missing.md)')
            nested = docs / 'worktrees/other'
            nested.mkdir(parents=True)
            (nested / 'ignored.md').write_text('unrelated checkout')
            with patch.object(checker, 'ROOT', root):
                self.assertEqual(checker.iter_text_files(docs), [current])
                self.assertFalse(checker.local_link_exists(current, 'missing.md'))


if __name__ == '__main__':
    unittest.main()
