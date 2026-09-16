#!/usr/bin/env python3
"""Retained repetition summaries; incomplete series never become accepted scores."""
import json
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def spread(values):
    values = [v for v in values if v is not None]
    return {"count": len(values), "median": statistics.median(values) if values else None,
            "min": min(values) if values else None, "max": max(values) if values else None}


def summarize(records):
    groups = {}
    for record in records:
        key = (record["lineage"], record["lane"], record.get("workload"))
        groups.setdefault(key, []).append(record)
    rows = []
    metrics = ["elapsed_seconds", "units_per_second", "sampled_peak_service_rss_bytes",
               "maximum_observed_service_vm_hwm_bytes", "sampled_peak_service_cpu_percent",
               "c_write_count", "wal_sync_count", "datadir_bytes"]
    for (lineage, lane, workload), all_rows in sorted(groups.items()):
        measured = [r for r in all_rows if not r["warmup"]]
        passed = [r for r in measured if r["status"] == "passed"]
        indices = sorted(r["repetition"] for r in passed)
        warmups = [r for r in all_rows if r["warmup"]]
        accepted = (len(warmups) == 1 and warmups[0]["status"] == "passed"
                    and len(measured) == 7 and indices == list(range(1, 8)))
        rows.append({"lineage": lineage, "lane": lane, "workload": workload,
                     "accepted": accepted, "measured_attempts": len(measured),
                     "passed_repetition_indices": indices,
                     "failures": [r.get("diagnostics") for r in all_rows if r["status"] != "passed"],
                     "metrics": {m: spread([r.get(m) for r in passed]) for m in metrics},
                     "request_latency_ns": {m: spread([r.get("latency_ns", {}).get(m) for r in passed])
                                            for m in ["median", "p95", "p99", "max"]},
                     "batch_histograms": [r.get("batch_size_histogram", {}) for r in passed]})
    comparisons = []
    lookup = {(r["lineage"], r["lane"], r["workload"]): r for r in rows}
    for row in rows:
        if row["lane"] != "baseline":
            continue
        optimized = lookup.get((row["lineage"], "optimization", row["workload"]))
        eligible = row["accepted"] and optimized is not None and optimized["accepted"]
        baseline_time = row["metrics"]["elapsed_seconds"]["median"]
        optimized_time = optimized["metrics"]["elapsed_seconds"]["median"] if optimized else None
        comparisons.append({"lineage": row["lineage"], "workload": row["workload"],
                            "accepted": bool(eligible),
                            "elapsed_reduction_fraction": 1 - optimized_time / baseline_time if eligible else None,
                            "baseline_median_seconds": baseline_time,
                            "optimized_median_seconds": optimized_time})
    return {"schema": "rosettanode.substrate.measurement_rollup.v1",
            "classification": "comparison", "binary_gate_status": "not_attempted",
            "rows": rows, "within_lineage_optimization": comparisons,
            "interpretation": "Individual lineage summaries; no pooled language ranking. Sample maxima are not continuous peaks. Request latency is distinct from durable admission-to-terminal latency. Incomplete or duplicated series are not accepted."}


if __name__ == "__main__":
    records = [json.loads(p.read_text()) for p in sorted((ROOT / "evidence").glob("repetition-*.json"))]
    (ROOT / "evidence/measurement-rollup.json").write_text(json.dumps(summarize(records), indent=2) + "\n")
