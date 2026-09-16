#!/usr/bin/env python3
"""Run isolated Core P2P comparisons; never import them as port evidence."""
import argparse
from collections import Counter
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import statistics
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
REFERENCE = ROOT / "Nodes/Reference"
COMPOSE = REFERENCE / "docker/core-comparison.yml"
TOPOLOGY = ROOT / "Nodes/Shared/docker/reference_topology.env"
OUTPUT = ROOT / "Nodes/Shared/conformance/core_comparisons"
SCHEMA = "rb.core_sync_comparison.v1"
HASH = "000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2"
LABEL = "rb.core_comparison"
TIMEOUT = 900


def command(args, *, timeout=60, env=None):
    p = subprocess.run(args, text=True, capture_output=True, timeout=timeout, env=env)
    if p.returncode:
        raise RuntimeError(f"{args[0:3]} exited {p.returncode}: {p.stderr.strip()}")
    return p.stdout.strip()


def docker(*args, **kwargs):
    return command(["docker", *args], **kwargs)


def inspect(kind, name):
    return json.loads(docker(kind, "inspect", name))[0]


def write_json(path, value):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    temp.replace(path)


def topology(path):
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            key, value = line.split("=", 1)
            values[key] = value.strip().strip("\"'")
    for key in ("REFERENCE_DOCKER_NETWORK", "REFERENCE_P2P_PEER"):
        if not values.get(key):
            raise ValueError(f"Missing {key} in {path}")
    return values


def rpc(container, *args, source=False):
    conf = ["-conf=/config/bitcoin.conf"] if source else ["-chain=testnet4", "-datadir=/home/bitcoin/.bitcoin"]
    raw = docker("exec", container, "bitcoin-cli", *conf, *args)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


def check_state(chain, utxo):
    expected = {"chain": "testnet4", "blocks": 5000, "bestblockhash": HASH}
    for key, value in expected.items():
        if chain.get(key) != value:
            raise ValueError(f"persisted {key}: expected {value}, got {chain.get(key)}")
    for key, value in {"height": 5000, "bestblock": HASH, "txouts": 4574}.items():
        if utxo.get(key) != value:
            raise ValueError(f"UTXO {key}: expected {value}, got {utxo.get(key)}")
    if chain.get("headers", -1) < 5000:
        raise ValueError("header height below target")


def summarize(runs):
    measured = [r for r in runs if r["measured"]]
    if len(measured) != 3 or any(r.get("result") != "passed" for r in measured):
        raise ValueError("Exactly three passing measured runs required")
    values = [r["elapsed_ms"] for r in measured]
    if any(not math.isfinite(v) or v <= 0 for v in values):
        raise ValueError("Invalid elapsed time")
    median = statistics.median(values)
    return {"measured_runs": 3, "median_elapsed_ms": median,
            "min_elapsed_ms": min(values), "max_elapsed_ms": max(values),
            "effective_blocks_per_second": 5_000_000 / median}


def validate(artifact):
    if artifact.get("schema") != SCHEMA or artifact.get("evidence_kind") != "comparison":
        raise ValueError("Not a Core comparison artifact")
    if artifact.get("binary_gate_status") != "not_attempted":
        raise ValueError("Comparison cannot claim tip readiness")
    if artifact.get("result") != "passed":
        raise ValueError("Campaign did not pass")
    if artifact.get("cleanup_errors"):
        raise ValueError("Campaign cleanup incomplete")
    runs = artifact["runs"]
    if len(runs) != 4 or [r["measured"] for r in runs] != [False, True, True, True]:
        raise ValueError("One warm-up and three measurements required")
    if len({r["volume"] for r in runs}) != 4:
        raise ValueError("Reused receiver volume")
    for run in runs:
        if run["result"] != "passed" or run["exit_code"] != 0 or not run["fresh_state"]:
            raise ValueError("Invalid run lifecycle")
        check_state(run["chainstate"], run["utxo"])
        resources = run["resources"]
        if resources.get("error") or resources.get("sample_count", 0) < 1:
            raise ValueError("Missing or failed resource sampling")
        for key in ("observed_peak_memory_bytes", "observed_peak_cpu_percent", "mean_sampled_cpu_percent"):
            value = resources.get(key)
            if not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                raise ValueError(f"Invalid resource measurement: {key}")
        if run["datadir_allocated_bytes"] <= 0 or run["relay"]["known_bounded_headers"] != 5000:
            raise ValueError("Missing disk or relay evidence")
    config = artifact["configuration"]
    for key, expected in {"assumevalid": "0", "cpus": 4, "memory_bytes": 4 * 1024**3,
                          "dbcache_mib": 450, "par": 4, "target_height": 5000}.items():
        if config.get(key) != expected:
            raise ValueError(f"Unexpected configuration: {key}")
    if "@sha256:" not in config.get("image", "") or "@sha256:" not in config.get("relay_image", ""):
        raise ValueError("Images are not pinned")
    if artifact["summary"] != summarize(runs):
        raise ValueError("Summary disagrees with measurements")


def owned_remove(kind, name, campaign):
    data = inspect(kind, name)
    labels = data.get("Labels") if kind == "volume" else data["Config"].get("Labels")
    if (labels or {}).get(LABEL) != campaign:
        raise RuntimeError(f"Refusing cleanup of unowned {kind} {name}")
    if kind == "container" and data["State"]["Running"]:
        docker("stop", "--time", "30", name)
    docker(kind, "rm", name)


class Samples:
    def __init__(self, name, path):
        self.name, self.path = name, path
        self.rows = []
        self.process = None
        self.error = None
        self.thread = threading.Thread(target=self.collect, daemon=True)

    def collect(self):
        try:
            self.process = subprocess.Popen(
                ["docker", "stats", "--format", "{{json .}}", self.name],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            with self.path.open("w") as out:
                for line in self.process.stdout:
                    clean = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", line).strip()
                    if not clean:
                        continue
                    row = json.loads(clean)
                    row["monotonic_s"] = time.monotonic()
                    self.rows.append(row)
                    out.write(json.dumps(row) + "\n")
                    out.flush()
        except Exception as exc:
            self.error = str(exc)

    def stop(self):
        if self.process:
            self.process.terminate()
        if self.process:
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        self.thread.join(timeout=5)
        memory, cpu = [], []
        for row in self.rows:
            number = row.get("MemUsage", "").split("/")[0].strip()
            for suffix, multiplier in (("GiB", 1024**3), ("MiB", 1024**2), ("KiB", 1024), ("B", 1)):
                if number.endswith(suffix):
                    memory.append(float(number[:-len(suffix)]) * multiplier)
                    break
            cpu.append(float(row.get("CPUPerc", "0%").rstrip("%")))
        gaps = [b["monotonic_s"] - a["monotonic_s"] for a, b in zip(self.rows, self.rows[1:])]
        return {"sample_count": len(self.rows), "observed_peak_memory_bytes": max(memory, default=None),
                "observed_peak_cpu_percent": max(cpu, default=None),
                "mean_sampled_cpu_percent": statistics.mean(cpu) if cpu else None,
                "max_sample_interval_s": max(gaps, default=None),
                "method": "docker stats stream, daemon cadence approximately 1 second; sampled maxima",
                "error": self.error}


def timed_sync(name, samples, timeout=TIMEOUT):
    # The waiter measures exit, independently of RPC polling and resource sampling.
    waiter = None
    start = time.monotonic()
    try:
        docker("start", name, timeout=min(60, timeout))
        waiter = subprocess.Popen(["docker", "wait", name], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        samples.thread.start()
        remaining = max(0.01, timeout - (time.monotonic() - start))
        out, err = waiter.communicate(timeout=remaining)
        elapsed = (time.monotonic() - start) * 1000
        if waiter.returncode:
            raise RuntimeError(f"docker wait failed: {err}")
        return int(out.strip()), elapsed
    finally:
        if waiter is not None and waiter.poll() is None:
            waiter.terminate()
            waiter.communicate(timeout=5)



class Campaign:
    def __init__(self, topology_path):
        self.id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
        self.path = REFERENCE / "comparison-runtime" / self.id
        self.path.mkdir(parents=True)
        self.topology_path = topology_path.resolve()
        self.topology = topology(topology_path)
        self.containers, self.volumes = [], []
        self.artifact = {"schema": SCHEMA, "evidence_kind": "comparison", "campaign_id": self.id,
                         "binary_gate_status": "not_attempted", "result": "failed", "runs": [],
                         "started_at": dt.datetime.now(dt.timezone.utc).isoformat()}

    def preflight(self):
        process_args = command(["ps", "-axo", "args="])
        if re.search(r"(?:run_benchmark_campaign|run_parallel_benchmark_campaign|run_crypto_lane|control_benchmark_harness)\.py(?:\s|$)", process_args):
            raise RuntimeError("Another node benchmark is active; wait for it before running")
        info = json.loads(docker("info", "--format", "{{json .}}"))
        network = inspect("network", self.topology["REFERENCE_DOCKER_NETWORK"])
        host = self.topology["REFERENCE_P2P_PEER"].rsplit(":", 1)[0]
        candidates = []
        for cid in network.get("Containers", {}):
            data = inspect("container", cid)
            aliases = data["NetworkSettings"]["Networks"][network["Name"]].get("Aliases") or []
            if host in [data["Name"].lstrip("/"), *aliases]:
                candidates.append(data)
        if len(candidates) != 1:
            raise RuntimeError("Reference peer must identify exactly one container on shared network")
        source = candidates[0]
        name = source["Name"].lstrip("/")
        chain = rpc(name, "getblockchaininfo", source=True)
        if chain["chain"] != "testnet4" or chain["blocks"] < 5000 or chain["pruned"]:
            raise RuntimeError("Reference must serve unpruned testnet4 history through 5000")
        if rpc(name, "getblockhash", "5000", source=True) != HASH:
            raise RuntimeError("Reference checkpoint mismatch")
        rpc(name, "getblock", HASH, "0", source=True)
        genesis = rpc(name, "getblockhash", "1", source=True)
        rpc(name, "getblock", genesis, "0", source=True)
        image = inspect("image", "bitcoin/bitcoin:28.2")
        digests = [x for x in image.get("RepoDigests", []) if x.startswith("bitcoin/bitcoin@sha256:")]
        if not digests:
            raise RuntimeError("Local bitcoin/bitcoin:28.2 has no immutable repository digest; pull it before running")
        self.image = digests[0]
        relay_image = inspect("image", "python:3.12-alpine")
        relay_digests = [x for x in relay_image.get("RepoDigests", []) if x.startswith("python@sha256:")]
        if not relay_digests:
            raise RuntimeError("Pull python:3.12-alpine before running; immutable digest required")
        self.relay_image = relay_digests[0]
        self.genesis = rpc(name, "getblockhash", "0", source=True)
        if inspect("image", self.image)["Id"] != image["Id"]:
            raise RuntimeError("Image tag/digest mismatch")
        source_image = inspect("image", source["Image"])
        self.artifact.update({
            "configuration": {"relay_image": self.relay_image, "relay": "v1 P2P relay withholding block requests and payloads beyond 5000; unchanged headers; overhead included", "v2transport": False, "image": self.image, "image_id": image["Id"], "cpus": 4,
                              "memory_bytes": 4 * 1024**3, "dbcache_mib": 450, "par": 4,
                              "assumevalid": "0", "target_height": 5000, "timeout_seconds": TIMEOUT,
                              "topology": self.topology, "cache_policy": "warm-source, fresh-receiver; no host cache clearing",
                              "timing_boundary": "monotonic receiver start request through process exit; includes durable shutdown; excludes preparation and inspection"},
            "source": {"container": name, "image_id": source["Image"],
                       "image": source["Config"]["Image"], "digests": source_image.get("RepoDigests", []),
                       "network_info": rpc(name, "getnetworkinfo", source=True), "chain_at_start": chain},
            "environment": {"host": platform.platform(), "host_architecture": platform.machine(),
                            "docker_version": json.loads(docker("version", "--format", "{{json .}}")),
                            "docker": {k: info.get(k) for k in ("Architecture", "OperatingSystem", "NCPU", "MemTotal", "Driver", "KernelVersion")},
                            "background_containers": docker("ps", "--format", "{{.Names}} {{.Image}}" ).splitlines(),
                            "host_process_counts": dict(Counter(Path(p).name for p in command(["ps", "-axo", "comm="]).splitlines()))},
            "implementation_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                      for p in (Path(__file__), COMPOSE, REFERENCE / "scripts/core_5k_relay.py")},
        })
        if info["NCPU"] < 4 or info["MemTotal"] < 4 * 1024**3:
            raise RuntimeError("Docker needs at least 4 CPUs and 4 GiB for this configuration")

    def compose(self, name, volume):
        env = dict(os.environ, **self.topology, CORE_COMPARISON_IMAGE=self.image,
                   CORE_COMPARISON_CONTAINER=name, CORE_COMPARISON_VOLUME=volume,
                   CORE_COMPARISON_ID=self.id, CORE_COMPARISON_RELAY=name + "-relay",
                   CORE_COMPARISON_RELAY_IMAGE=self.relay_image, REFERENCE_GENESIS_HASH=self.genesis)
        args = ["docker", "compose", "--env-file", str(self.topology_path), "-p", name,
                "-f", str(COMPOSE)]
        command([*args, "config", "--quiet"], env=env)
        command([*args, "create", "--pull", "never", "receiver", "relay"], env=env)

    def inspect_state(self, volume, run):
        name = "rb-core-inspect-" + self.id.lower() + "-" + str(run["index"])
        self.containers.append(name)
        docker("create", "--name", name, "--network", "none", "--label", f"{LABEL}={self.id}",
               "--cpus", "4", "--memory", "4g", "-v", f"{volume}:/home/bitcoin/.bitcoin",
               self.image, "-chain=testnet4", "-server=1", "-networkactive=0", "-listen=0",
               "-assumevalid=0", "-dbcache=450", "-par=4", "-disablewallet=1")
        docker("start", name)
        deadline = time.monotonic() + 60
        while True:
            try:
                chain = rpc(name, "getblockchaininfo")
                break
            except RuntimeError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Inspection RPC did not become ready")
                time.sleep(0.2)
        run["chainstate"] = chain
        run["utxo"] = rpc(name, "gettxoutsetinfo")
        run["receiver_version"] = rpc(name, "getnetworkinfo")["subversion"]
        rpc(name, "stop")
        if docker("wait", name) != "0":
            raise RuntimeError("Inspection failed to shut down cleanly")
        check_state(chain, run["utxo"])
        size = docker("run", "--rm", "--network", "none", "--entrypoint", "du",
                      "-v", f"{volume}:/data:ro", self.image, "-sk", "/data")
        run["datadir_allocated_bytes"] = int(size.split()[0]) * 1024

    def run_one(self, index):
        name = "rb-core-" + self.id.lower() + "-" + str(index)
        volume = name + "-data"
        run = {"index": index, "measured": index > 0, "volume": volume,
               "container": name, "result": "failed", "fresh_state": False}
        self.artifact["runs"].append(run)
        # A collision must fail, not turn Docker's idempotent volume create into reuse.
        existing = docker("volume", "ls", "--format", "{{.Name}}").splitlines()
        if volume in existing:
            raise RuntimeError("Refusing existing receiver volume")
        docker("volume", "create", "--label", f"{LABEL}={self.id}", volume)
        self.volumes.append(volume)
        run["fresh_state"] = True
        self.containers.append(name)
        relay = name + "-relay"
        self.containers.append(relay)
        self.compose(name, volume)
        docker("start", relay)
        deadline = time.monotonic() + 30
        while "relay_ready" not in docker("logs", relay):
            if time.monotonic() >= deadline:
                raise RuntimeError("Relay did not become ready")
            time.sleep(0.1)
        run["command"] = inspect("container", name)["Config"]["Cmd"]
        samples = Samples(name, self.path / f"run-{index}-stats.jsonl")
        print(f"{'warm-up' if index == 0 else 'measured'} run {index}: starting", flush=True)
        try:
            run["exit_code"], run["elapsed_ms"] = timed_sync(name, samples)
        finally:
            try:
                if samples.thread.ident is not None:
                    run["resources"] = samples.stop()
            finally:
                (self.path / f"run-{index}.log").write_text(docker("logs", name))
        if run["exit_code"] != 0:
            raise RuntimeError(f"Receiver exit code {run['exit_code']}")
        if run["resources"]["error"] or not run["resources"]["sample_count"]:
            raise RuntimeError("Resource sampling failed; retain diagnostics and rerun a new campaign")
        if docker("wait", relay) != "0":
            raise RuntimeError("Bounded P2P relay failed")
        relay_log = docker("logs", relay)
        (self.path / f"run-{index}-relay.log").write_text(relay_log)
        run["relay"] = json.loads(relay_log.splitlines()[-1])
        self.inspect_state(volume, run)
        run["effective_blocks_per_second"] = 5_000_000 / run["elapsed_ms"]
        run["result"] = "passed"
        print(f"run {index}: passed {run['elapsed_ms']/1000:.3f}s; headers={run['chainstate']['headers']}; UTXOs=4574", flush=True)

    def execute(self):
        try:
            self.preflight()
            for index in range(4):
                self.run_one(index)
            self.artifact["summary"] = summarize(self.artifact["runs"])
            self.artifact["result"] = "passed"
            validate(self.artifact)
        except (Exception, KeyboardInterrupt) as exc:
            self.artifact["result"] = "failed"
            self.artifact["failure"] = f"{type(exc).__name__}: {exc}"
            if self.artifact["runs"] and self.artifact["runs"][-1]["result"] != "passed":
                self.artifact["runs"][-1]["failure"] = self.artifact["failure"]
        finally:
            self.artifact["finished_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
            cleanup_errors = []
            for name in reversed(self.containers):
                try:
                    data = inspect("container", name)
                    if (data["Config"].get("Labels") or {}).get(LABEL) != self.id:
                        raise RuntimeError(f"Refusing cleanup of unowned container {name}")
                    if data["State"]["Running"]:
                        docker("stop", "--time", "30", name)
                    (self.path / f"{name}.log").write_text(docker("logs", name))
                    owned_remove("container", name, self.id)
                except Exception as exc:
                    cleanup_errors.append(str(exc))
            self.artifact["cleanup_errors"] = cleanup_errors
            if cleanup_errors:
                self.artifact["result"] = "failed"
                self.artifact.setdefault("failure", "Campaign cleanup incomplete; retained volumes")
            self.artifact["runtime_logs"] = str(self.path.relative_to(ROOT))
            OUTPUT.mkdir(parents=True, exist_ok=True)
            output = OUTPUT / f"core_5k_{self.id}.json"
            write_json(output, self.artifact)
            if self.artifact["result"] == "passed" and not cleanup_errors:
                for volume in self.volumes:
                    try:
                        owned_remove("volume", volume, self.id)
                    except Exception as exc:
                        cleanup_errors.append(str(exc))
                if cleanup_errors:
                    self.artifact["result"] = "failed"
                    self.artifact["failure"] = "Volume cleanup incomplete"
                write_json(output, self.artifact)
            print(f"artifact: {output}", flush=True)
        if self.artifact["result"] != "passed":
            print(self.artifact["failure"], file=sys.stderr)
            return 1
        print(json.dumps(self.artifact["summary"], indent=2))
        return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate", type=Path, help="validate an existing campaign without Docker")
    args = parser.parse_args()
    if args.validate:
        validate(json.loads(args.validate.read_text()))
        print("Core comparison artifact valid")
        return 0
    runtime = REFERENCE / "comparison-runtime"
    runtime.mkdir(exist_ok=True)
    with (runtime / "campaign.lock").open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("Another Core comparison campaign holds the lock")
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt("SIGTERM")))
        return Campaign(Path(os.environ.get("REFERENCE_TOPOLOGY_ENV", TOPOLOGY))).execute()


if __name__ == "__main__":
    sys.exit(main())
