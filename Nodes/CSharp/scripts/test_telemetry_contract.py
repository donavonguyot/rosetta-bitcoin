#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import tempfile
import unittest


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REFERENCE_PEER = "reference-peer:48333"


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
    "peer_source": REFERENCE_PEER,
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
                "baseline_5k",
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
                "--event",
                "heartbeat",
                "--run-id",
                "csharp-test-run",
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
        self.assertEqual(tick["gate"], "baseline_5k")
        self.assertEqual(tick["run_id"], "csharp-test-run")
        self.assertEqual(tick["event"], "heartbeat")
        self.assertEqual(tick["phase"], "heartbeat")
        self.assertEqual(tick["stall_class"], "none")
        self.assertEqual(tick["target_height"], 5000)
        self.assertEqual(tick["height"], 5000)
        self.assertEqual(tick["utxos"], 4574)
        self.assertEqual(tick["last_block_ms"], 60)
        self.assertEqual(tick["current_block_height"], 5000)
        self.assertEqual(tick["current_block_tx_count"], 2)
        self.assertEqual(tick["current_block_vin_count"], 4)
        self.assertEqual(tick["current_block_script_input_count"], 3)
        self.assertEqual(tick["timing_buckets_ms"]["script_verify"], 2500)
        self.assertEqual(tick["timing_buckets_ms"]["block_connect_store_commit"], 4100)

    def test_capture_adds_shared_telemetry_fields_without_dropping_csharp_timing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            status_path = tmp_path / "status.json"
            exit_path = tmp_path / "exit"
            proof_path = tmp_path / "proof.json"
            telemetry_log = tmp_path / "telemetry.log"
            status_path.write_text(json.dumps(SAMPLE_STATUS))
            exit_path.write_text("0\n")
            tick_base = {
                "schema": "benchmark.telemetry_tick.v1",
                "port": "csharp",
                "gate": "baseline_5k",
                "run_id": "csharp-test-run",
                "phase": "heartbeat",
                "height": 5000,
                "target_height": 5000,
                "percent": 100,
                "elapsed_ms": 0,
                "monotonic_ms": 0,
                "utxos": 4574,
                "current_blocker": None,
                "stall_class": "none",
                "current_block_elapsed_ms": 0,
                "current_block_height": 5000,
                "current_block_hash": SAMPLE_STATUS["validated_hash"],
                "current_block_tx_count": 2,
                "current_block_vin_count": 4,
                "current_block_script_input_count": 3,
                "rate_recent_blocks_per_second": 0,
                "rate_total_blocks_per_second": 0,
                "last_block_ms": 0,
                "timing_buckets_ms": {
                    "p2p_fetch": 0,
                    "block_parse_validate": 0,
                    "utxo_load": 0,
                    "script_verify": 0,
                    "utxo_apply": 0,
                    "commit": 0,
                    "block_connect_store_commit": 0,
                },
            }
            events = [
                ("run_started", "startup", 0),
                ("container_started", "startup", 1000),
                ("node_started", "startup", 2000),
                ("first_peer_byte", "peer_connect", 3000),
                ("first_block_connected", "block_connect", 4000),
                ("target_reached", "complete", 5000),
                ("run_finished", "complete", 6000),
            ]
            telemetry_log.write_text(
                "\n".join(
                    "benchmark.telemetry_tick "
                    + json.dumps({**tick_base, "event": event, "phase": phase, "elapsed_ms": ms, "monotonic_ms": ms})
                    for event, phase, ms in events
                )
                + "\n"
            )
            env = os.environ.copy()
            env.update(
                {
                    "PROOF_PATH": str(proof_path),
                    "RUN_FILE": str(tmp_path / "missing-run.json"),
                    "TELEMETRY_LOG_PATH": str(telemetry_log),
                    "STANDARD_BENCHMARK_ARTIFACT": "1",
                    "TARGET_HEADER_HEIGHT": "5000",
                    "TARGET_BLOCK_HEIGHT": "5000",
                    "BLOCK_PREFETCH_DEPTH": "4",
                    "SCRIPT_RUNNER_MODE": "parallel",
                    "PEERS": REFERENCE_PEER,
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
        self.assertEqual(artifact["telemetry_summary"]["telemetry_quality"], "clean")
        self.assertEqual(artifact["pipeline_timing_summary"]["stage_totals_ms"]["script_verify"], 2500)
        self.assertEqual(artifact["timing_summary"]["stage_totals_ms"]["commit"], 500)
        self.assertIn("sync_timing", artifact)
        self.assertEqual(artifact["result"], "passed")


if __name__ == "__main__":
    unittest.main()
