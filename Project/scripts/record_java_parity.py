"""Record or compare Java test identities and outcomes from Surefire XML."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

from state_root import ROOT


def snapshot(reports: Path) -> dict:
    cases = []
    for path in sorted(reports.glob("TEST-*.xml")):
        for case in ET.parse(path).getroot().iter("testcase"):
            outcome = next((tag for tag in ("failure", "error", "skipped") if case.find(tag) is not None), "passed")
            cases.append({"class": case.get("classname"), "name": case.get("name"), "outcome": outcome})
    if not cases or any(c["outcome"] in ("failure", "error") for c in cases):
        raise ValueError("Java parity requires a nonempty passing baseline and candidate")
    return {"schema": "rb.java_fixture_parity.v1", "cases": sorted(cases, key=lambda c: (c["class"], c["name"])),
            "count": len(cases), "skipped": sum(c["outcome"] == "skipped" for c in cases)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reports", type=Path, default=ROOT / "Nodes/Java/target/surefire-reports")
    parser.add_argument("--record", type=Path)
    parser.add_argument("--compare", type=Path)
    args = parser.parse_args()
    result = snapshot(args.reports)
    if args.compare and json.loads(args.compare.read_text()) != result:
        raise ValueError("Java test identities or outcomes differ")
    if args.record:
        args.record.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"result": "passed", "count": result["count"], "skipped": result["skipped"]}))


if __name__ == "__main__":
    main()
