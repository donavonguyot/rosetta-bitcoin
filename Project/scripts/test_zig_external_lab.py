import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from run_zig_external_lab import Lab, STATUS_FIELDS, TIP_5K, check_restart, verify_source


class ExternalLabTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / 'source'
        self.source.mkdir()
        names = ('docker/Dockerfile', 'build.zig', 'src/cli/main.zig', 'libsecp256k1-zig/build.zig',
                 'fixtures/conformance/fixtures/scripts/manifest.json')
        self.manifest = {'schema': 'zigbitnode.standalone_source.v1', 'source_dirty': False,
                         'source_commit': 'a' * 40, 'zig_version': '0.16.0', 'files': []}
        for name in names:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
            self.manifest['files'].append({'path': name, 'sha256': hashlib.sha256(name.encode()).hexdigest()})
        self.inventory = self.source / 'standalone-manifest.json'
        self.inventory.write_text(json.dumps(self.manifest))

    def verify(self):
        return verify_source(self.source, self.inventory, self.base / 'rb')

    def test_accepts_external_inventory(self):
        self.assertEqual(self.verify(), self.manifest)

    def test_rejects_modified_missing_and_extra_source(self):
        target = self.source / 'build.zig'
        target.write_text('changed')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.verify()
        target.unlink()
        with self.assertRaises(FileNotFoundError):
            self.verify()
        target.write_text('build.zig')
        (self.source / 'surprise.zig').write_text('extra')
        with self.assertRaisesRegex(ValueError, 'uninventoried'):
            self.verify()

    def test_rejects_internal_dirty_and_escaping_source(self):
        with self.assertRaisesRegex(ValueError, 'outside RB'):
            verify_source(self.source, self.inventory, self.base)
        self.manifest['source_dirty'] = True
        self.inventory.write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, 'clean source'):
            self.verify()
        self.manifest['source_dirty'] = False
        self.manifest['files'][0]['path'] = '../escape'
        self.inventory.write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            self.verify()

    def test_rejects_symlink(self):
        (self.source / 'extra').symlink_to(self.base)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.verify()

    def test_cleanup_only_removes_the_container_this_run_created(self):
        lab = object.__new__(Lab)
        lab.source, lab.directory = self.source, self.base
        lab.run_id, lab.image = 'zig-external-test', 'sha256:' + 'a' * 64
        with patch.object(lab, 'run', side_effect=ValueError('name collision')), patch('run_zig_external_lab.subprocess.run') as cleanup:
            with self.assertRaises(ValueError):
                lab.container('status', ['status'])
            cleanup.assert_not_called()
        identity = 'b' * 64
        (self.base / 'status.cid').write_text(identity)
        with patch.object(lab, 'run', side_effect=TimeoutError()), patch('run_zig_external_lab.subprocess.run') as cleanup:
            with self.assertRaises(TimeoutError):
                lab.container('status', ['status'])
            self.assertEqual(cleanup.call_args.args[0], ['docker', 'rm', '-f', identity])

    def test_restart_requires_persisted_tip_set_and_no_replay(self):
        before = dict.fromkeys(STATUS_FIELDS)
        before.update(validated_height=5000, header_height=5000, stored_block_height=5000,
                      validated_hash=TIP_5K, header_hash=TIP_5K, stored_block_hash=TIP_5K,
                      chainstate_set_hash='b' * 64, chainstate_utxo_count=4574,
                      chainstate_backend='rocksdb', chainstate_status='usable',
                      native_crypto_backend='libsecp256k1', sync_status='blocks_current', current_blocker=None)
        resumed = {**before, 'fresh_state': False, 'blocks_connected': 0, 'blocks_fetched': 0}
        check_restart(before, before, resumed)
        for key, bad in [('validated_hash', 'c' * 64), ('chainstate_utxo_count', 0),
                         ('chainstate_set_hash', 'c' * 64), ('native_crypto_backend', 'pure')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                check_restart(before, {**before, key: bad}, resumed)
        for change in ({'fresh_state': True}, {'blocks_connected': 5001}, {'blocks_fetched': 1},
                       {'chainstate_set_hash': 'c' * 64}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                check_restart(before, before, {**resumed, **change})


if __name__ == '__main__':
    unittest.main()
