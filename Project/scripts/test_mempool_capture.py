"""Offline regression checks for the integrated watcher and trace diagnostics."""
import argparse
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import Mock, patch

import capture_mempool_trace as capture
import testnet4_activity as activity


class CaptureTest(unittest.TestCase):
    def test_existing_trace_semantics(self):
        capture.self_test()

    def test_unmet_coverage_never_publishes(self):
        parent = capture.Tx(capture.build_tx(bytes(32), 0, [(1000, b'\x51')]))
        live = [{'kind': 'tx', 'raw': parent.raw, 'capture_seq': 1, 'ms': 0, 'preface': False}]
        with tempfile.TemporaryDirectory() as temp, patch.object(capture, 'FIXTURE_ROOT', Path(temp)):
            destination, coverage = capture.publish([], live, {}, {'blocks': 10, 'bestblockhash': '00' * 32}, 'test', False, min_tx=1)
            self.assertIsNone(destination)
            self.assertEqual(coverage['status'], 'unmet')
            self.assertEqual(list(Path(temp).iterdir()), [])

    def test_reorg_window_cannot_be_published(self):
        args = argparse.Namespace(max_seconds=1, max_bytes=1000, min_tx=1)
        rpc = Mock()
        rpc.call.return_value = {'subversion': 'test'}
        with patch.object(capture, 'snapshot_preface', return_value=[]), \
             patch.object(capture, 'capture_window', return_value=([], [], {'started': 0, 'ended': 1, 'stop': 'reorg'})), \
             patch.object(capture, 'watch_log') as log, patch.object(capture, 'publish') as publish:
            self.assertFalse(capture.record_window(args, rpc, {'blocks': 10, 'bestblockhash': '00' * 32}, {}, {}))
            publish.assert_not_called()
            self.assertEqual(log.call_args.args[0]['discard_reason'], 'reorg')

    def test_quiet_poll_keeps_reader_until_real_connection_failure(self):
        meter = capture.ArrivalMeter()
        sock = Mock()
        meter.sock = sock
        with patch.object(capture, 'read_message', side_effect=[socket.timeout(), ('tx', b''), OSError('disconnected')]):
            meter._read_loop()
        self.assertEqual(len(meter.arrivals), 1)
        self.assertEqual(meter.failure, 'disconnected')
        sock.close.assert_called_once()

    def test_stale_template_is_not_reused_for_next_block(self):
        template = {'captured_unix_ms': 100, 'fees_sat': 42}
        self.assertIs(capture.gbt_for_block(template, 99), template)
        self.assertIsNone(capture.gbt_for_block(template, 101))
        self.assertIsNone(capture.gbt_for_block(None, 99))

    def test_activity_bursts_and_threshold_bounds(self):
        rows = [{'height': n, 'txs': 10 if n < 5 else 1} for n in range(6)]
        self.assertEqual(activity.bursts(rows, 1), [{'start_height': 0, 'length': 5}])
        self.assertEqual(activity.choose_thresholds(1, 0.01, [])['open_pool'], 200)
        self.assertEqual(activity.choose_thresholds(900, 0.01, [])['open_pool'], 500)


if __name__ == '__main__':
    unittest.main()
