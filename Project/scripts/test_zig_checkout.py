"""Cutover checks: fail closed and bind the executed external runtime to its inputs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import provenance
import zig_checkout as checkout
import test_zig_external_lab


class CheckoutTests(unittest.TestCase):
    def setUp(self):
        test_zig_external_lab.ExternalLabTests.setUp(self)
        self.environment = patch.dict(os.environ, {'RB_ZIG_SOURCE': str(self.source)}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_selector_never_falls_back(self):
        self.assertEqual(checkout.selected_source(), (self.source.resolve(), self.inventory.resolve()))
        with patch.dict(os.environ, {'RB_ZIG_SOURCE': ''}, clear=True):
            with self.assertRaisesRegex(ValueError, 'no bundled-source fallback'):
                checkout.selected_source()
        with self.assertRaisesRegex(ValueError, 'unsupported'):
            checkout.require_bundled('historical campaign')
        with patch('zig_checkout.prepare', return_value=({}, {})) as prepare:
            self.assertEqual(provenance.prepare_port('zig', 'test'), ({}, {}))
            prepare.assert_called_once_with('test')

    def test_external_make_rejects_host_fallback_before_execution(self):
        result = subprocess.run(['make', '-n', '-C', str(checkout.ROOT / 'Nodes/Zig'), 'build'],
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Docker lab targets only', result.stderr)
        result = subprocess.run(['make', '-n', '-C', str(checkout.ROOT / 'Nodes/Zig'), 'docker-build'],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('zig_checkout.py verify', result.stdout)
        self.assertIn('zig_checkout.py prepare', result.stdout)

    def test_cached_image_must_match_revision_and_binary(self):
        info = {'source_commit': 'a' * 40, 'store_mode': 'both', 'crypto_backend': 'c_binding',
                'binary_sha256': 'b' * 64}
        receipt = self.base / 'receipt.json'
        with patch('zig_checkout.primary_root', return_value=self.base / 'rb'), \
             patch('zig_checkout.PATHS', {'root': self.base / 'state'}), \
             patch('build_fixture_package.build', return_value={'fixture_hash': 'c' * 64}), \
             patch('build_fixture_package.unpack'), \
             patch('provenance.image_id', return_value='sha256:' + 'd' * 64), \
             patch('provenance.receipt_path', return_value=receipt), \
             patch('provenance.for_image', return_value={'source_commit': 'a' * 40}), \
             patch('zig_checkout.subprocess.check_output', side_effect=lambda args, **kw:
                   json.dumps(info) if '--build-info' in args else 'b' * 64 + '  /usr/local/bin/zigbitnode'), \
             patch('build_fixture_package.publish', side_effect=lambda path, data: path.write_bytes(data)):
            pins, env = checkout.prepare()
            self.assertEqual(env['RB_ZIG_CONTEXT'], str(self.source.resolve()))
            self.assertEqual(env['RB_ZIG_NODE_SOURCE'], '.')
            self.assertEqual(env['RB_PROVENANCE_IMAGE'], 'sha256:' + 'd' * 64)
            self.assertEqual(json.loads(receipt.read_text())['source_manifest_sha256'], checkout.digest(self.inventory))
            checkout.prepare()  # An identical receipt is reusable.
            info['source_commit'] = 'e' * 40
            with self.assertRaisesRegex(ValueError, 'source_commit mismatch'):
                checkout.prepare()
            info['source_commit'] = 'a' * 40
            info['binary_sha256'] = 'f' * 64
            with self.assertRaisesRegex(ValueError, 'binary hash mismatch'):
                checkout.prepare()
            info['binary_sha256'] = 'b' * 64
            receipt.write_text('{}')
            with self.assertRaisesRegex(ValueError, 'receipt mismatch'):
                checkout.prepare()


if __name__ == '__main__':
    unittest.main()
