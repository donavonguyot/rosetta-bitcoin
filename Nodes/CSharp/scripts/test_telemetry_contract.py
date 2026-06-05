#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import tempfile
import unittest


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent


SAMPLE_STATUS = {
    "validated_height": 5000,
    "validated_hash": "000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2",
    "header_height": 5000,
    "stored_block_height": 5000,
    "sync_status": "blocks_current",
    "utxo_count": 4574,
    "chainstate_backend": "rocksdb",
    "codec_version": "rocksdb-codec-v2",
    "chainstate_status": "ok",
    "native_crypto_backend": "libsecp256k1",
    "native_crypto_available": True,
    "taproot_tweak_backend": "libsecp256k1",
    "peer_source": "host.docker.internal:48333",
    "sync_timing": {
        "Unit": "microseconds",
        "Stages": {
            "p2p_fetch": {"Count": 5000, "TotalMicros": 150000, "P50Micros": 10, "P95Micros": 80, "MaxMicros": 1000},
            "script_verify": {"Count": 300, "TotalMicros": 2500000, "P50Micros": 200, "P95Micros": 3000, "MaxMicros": 50000},
            "commit": {"Count": 5000, "TotalMicros": 500000, "P50Micros": 80, "P95Micros": 200, "MaxMicros": 1500},
            "block_connect_store_commit": {"Count": 5000, "TotalMicros": 4100000, "P50Micros": 400, "P95Micros": 1200, "MaxMicros": 60000},
        },
        "SlowBlocks": [
            {
                "Height": 5000,
                "Micros": 60000,
                "TxCount": 2,
                "VinCount": 4,
                "VoutCount": 5,
                "ScriptInputCount": 3,
                "InputShapeCounts": {},
                "SpentPrevoutScriptTypes": {},
                "OutputScriptTypes": {},
            }
        ],
    },
}


class TelemetryContractTests(unittest.TestCase):
    def test_emitter_outputs_monitor_parseable_tick(self) -> None:
        proc = subprocess.run(
            [
                "python3",
                str(SCRIPT_DIR / "emit_benchmark_telemetry_tick.py"),
                "--gate",
                "supporting_5k",
                "--target-height",
                "5000",
                "--started-ms",
                "1000",
                "--last-height",
                "4750",
                "--poll-sec",
                "15",
                "--phase",
                "running",
                "--process-running",
                "1",
            ],
            input=json.dumps(SAMPLE_STATUS),
            text=True,
            capture_output=True,
            check=True,
        )
        prefix = "benchmark.telemetry_tick "
        self.assertTrue(proc.stdout.startswith(prefix), proc.stdout)
        tick = json.loads(proc.stdout[len(prefix) :])
        self.assertEqual(tick["schema"], "benchmark.telemetry_tick.v1")
        self.assertEqual(tick["port"], "csharp")
        self.assertEqual(tick["gate"], "supporting_5k")
        self.assertEqual(tick["target_height"], 5000)
        self.assertEqual(tick["height"], 5000)
        self.assertEqual(tick["utxos"], 4574)
        self.assertEqual(tick["last_block_ms"], 60)
        self.assertEqual(tick["timing_buckets_ms"]["script_verify"], 2500)
        self.assertEqual(tick["timing_buckets_ms"]["block_connect_store_commit"], 4100)

    def test_capture_adds_shared_telemetry_fields_without_dropping_csharp_timing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            status_path = tmp_path / "status.json"
            exit_path = tmp_path / "exit"
            proof_path = tmp_path / "proof.json"
            status_path.write_text(json.dumps(SAMPLE_STATUS))
            exit_path.write_text("0\n")
            env = os.environ.copy()
            env.update(
                {
                    "PROOF_PATH": str(proof_path),
                    "RUN_FILE": str(tmp_path / "missing-run.json"),
                    "STANDARD_BENCHMARK_ARTIFACT": "1",
                    "TARGET_HEADER_HEIGHT": "5000",
                    "TARGET_BLOCK_HEIGHT": "5000",
                    "BLOCK_PREFETCH_DEPTH": "4",
                    "SCRIPT_RUNNER_MODE": "parallel",
                    "PEERS": "host.docker.internal:48333",
                }
            )
            subprocess.run(
                ["python3", str(SCRIPT_DIR / "capture_docker_sync_proof.py"), str(status_path), str(exit_path)],
                env=env,
                text=True,
                capture_output=True,
                check=True,
            )
            artifact = json.loads(proof_path.read_text())
        self.assertEqual(artifact["telemetry_schema"], "benchmark.telemetry_tick.v1")
        self.assertEqual(artifact["pipeline_timing_summary"]["stage_totals_ms"]["script_verify"], 2500)
        self.assertEqual(artifact["timing_summary"]["stage_totals_ms"]["commit"], 500)
        self.assertIn("sync_timing", artifact)
        self.assertEqual(artifact["result"], "passed")


if __name__ == "__main__":
    unittest.main()
