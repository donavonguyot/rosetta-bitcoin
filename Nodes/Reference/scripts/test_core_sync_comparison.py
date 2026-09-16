import copy
import subprocess
import unittest
from unittest.mock import Mock, patch
import core_sync_comparison as c


def run(index, elapsed=1000):
    return {"index": index, "measured": index > 0, "volume": str(index), "result": "passed",
            "fresh_state": True, "exit_code": 0, "elapsed_ms": elapsed,
            "resources": {"sample_count": 2, "error": None, "observed_peak_memory_bytes": 1024,
                          "observed_peak_cpu_percent": 100, "mean_sampled_cpu_percent": 50},
            "datadir_allocated_bytes": 4096, "relay": {"known_bounded_headers": 5000},
            "chainstate": {"chain": "testnet4", "blocks": 5000, "bestblockhash": c.HASH, "headers": 152000},
            "utxo": {"height": 5000, "bestblock": c.HASH, "txouts": 4574}}


class ComparisonTests(unittest.TestCase):
    def test_checkpoint_rejects_overshoot_wrong_hash_wrong_utxo(self):
        good = run(1)
        c.check_state(good["chainstate"], good["utxo"])
        for section, key, value in [("chainstate", "blocks", 5001), ("chainstate", "bestblockhash", "bad"),
                                    ("utxo", "txouts", 4575), ("utxo", "height", 4999)]:
            bad = copy.deepcopy(good)
            bad[section][key] = value
            with self.assertRaises(ValueError):
                c.check_state(bad["chainstate"], bad["utxo"])

    def test_summary_excludes_warmup_and_requires_all_three(self):
        runs = [run(0, 999999), run(1, 3000), run(2, 1000), run(3, 2000)]
        summary = c.summarize(runs)
        self.assertEqual(summary["median_elapsed_ms"], 2000)
        self.assertEqual(summary["effective_blocks_per_second"], 2500)
        runs[2]["result"] = "failed"
        with self.assertRaises(ValueError):
            c.summarize(runs)

    def test_validator_rejects_reuse_or_changed_summary(self):
        runs = [run(i) for i in range(4)]
        artifact = {"schema": c.SCHEMA, "evidence_kind": "comparison", "binary_gate_status": "not_attempted",
                    "result": "passed", "runs": runs, "summary": c.summarize(runs),
                    "configuration": {"assumevalid": "0", "cpus": 4, "memory_bytes": 4 * 1024**3,
                                      "dbcache_mib": 450, "par": 4, "target_height": 5000,
                                      "image": "bitcoin@sha256:abc", "relay_image": "python@sha256:def"}}
        c.validate(artifact)
        artifact["runs"][1]["resources"]["sample_count"] = 0
        with self.assertRaises(ValueError):
            c.validate(artifact)
        artifact["runs"][1]["resources"]["sample_count"] = 2
        artifact["runs"][1]["volume"] = "0"
        with self.assertRaises(ValueError):
            c.validate(artifact)
        artifact["runs"][1]["volume"] = "1"
        artifact["summary"]["median_elapsed_ms"] = 1
        with self.assertRaises(ValueError):
            c.validate(artifact)

    @patch.object(c.subprocess, "Popen")
    def test_resource_stream_accepts_docker_terminal_codes(self, popen):
        import tempfile
        from pathlib import Path
        popen.return_value.stdout = ["\n", "\x1b[H\n", '\x1b[H{"MemUsage":"2MiB / 4GiB", "CPUPerc":"125.5%"}\x1b[K\n']
        with tempfile.TemporaryDirectory() as directory:
            samples = c.Samples("receiver", Path(directory) / "stats.jsonl")
            samples.thread.start()
            samples.thread.join()
            result = samples.stop()
        self.assertIsNone(result["error"])
        self.assertEqual(result["sample_count"], 1)
        self.assertEqual(result["observed_peak_memory_bytes"], 2 * 1024**2)
        self.assertEqual(result["observed_peak_cpu_percent"], 125.5)

    @patch.object(c, "docker")
    @patch.object(c, "inspect")
    def test_cleanup_refuses_foreign_resources(self, inspect, docker):
        inspect.return_value = {"Labels": {c.LABEL: "other"}}
        with self.assertRaises(RuntimeError):
            c.owned_remove("volume", "source", "mine")
        docker.assert_not_called()
        inspect.return_value = {"Labels": {c.LABEL: "mine"}}
        c.owned_remove("volume", "own", "mine")
        docker.assert_called_once_with("volume", "rm", "own")

    @patch.object(c, "docker")
    @patch.object(c.subprocess, "Popen")
    @patch.object(c.time, "monotonic", side_effect=[10, 11, 13])
    def test_timing_includes_start_and_exit_only(self, clock, popen, docker):
        waiter = popen.return_value
        waiter.communicate.return_value = ("0\n", "")
        waiter.returncode = 0
        waiter.poll.return_value = 0
        samples = Mock()
        self.assertEqual(c.timed_sync("receiver", samples), (0, 3000))
        docker.assert_called_once_with("start", "receiver", timeout=60)
        waiter.communicate.assert_called_once_with(timeout=899)
        samples.thread.start.assert_called_once()
        samples.stop.assert_not_called()

    @patch.object(c, "docker")
    @patch.object(c.subprocess, "Popen")
    def test_timeout_terminates_waiter(self, popen, docker):
        waiter = popen.return_value
        waiter.communicate.side_effect = [subprocess.TimeoutExpired("wait", 900), ("", "")]
        waiter.poll.return_value = None
        with self.assertRaises(subprocess.TimeoutExpired):
            c.timed_sync("receiver", Mock())
        waiter.terminate.assert_called_once()

    @patch.object(c, "command")
    def test_compose_uses_digest_and_shared_topology(self, command):
        campaign = object.__new__(c.Campaign)
        campaign.id = "test"
        campaign.image = "bitcoin/bitcoin@sha256:abc"
        campaign.relay_image = "python@sha256:def"
        campaign.genesis = "00" * 32
        campaign.topology_path = c.TOPOLOGY
        campaign.topology = c.topology(c.TOPOLOGY)
        campaign.compose("receiver", "fresh")
        call = command.call_args
        self.assertIn("--env-file", call.args[0])
        self.assertEqual(call.args[0][call.args[0].index("-p") + 1], "receiver")
        self.assertEqual(call.args[0][-5:], ["create", "--pull", "never", "receiver", "relay"])
        self.assertEqual(call.kwargs["env"]["CORE_COMPARISON_IMAGE"], campaign.image)
        self.assertEqual(call.kwargs["env"]["CORE_COMPARISON_VOLUME"], "fresh")


if __name__ == "__main__":
    unittest.main()
