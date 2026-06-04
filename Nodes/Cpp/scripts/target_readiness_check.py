#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


REQUIRED_BLOCKERS = [
    739,
    6975,
    18675,
    22830,
    25207,
    27042,
    27251,
    27807,
    27815,
    27840,
    32712,
    32868,
    33500,
    38010,
    38191,
    41700,
    44295,
    46599,
    46779,
]


def height_patterns(height: int) -> list[re.Pattern[str]]:
    compact = str(height)
    comma = f"{height:,}"
    return [
        re.compile(rf"(?<!\d){re.escape(compact)}(?!\d)"),
        re.compile(rf"(?<!\d){re.escape(comma)}(?!\d)"),
    ]


def covered(height: int, text: str) -> bool:
    return any(pattern.search(text) for pattern in height_patterns(height))


def main() -> int:
    parser = argparse.ArgumentParser(description="Check C++ blocker coverage before long sync targets.")
    parser.add_argument("--target", type=int, required=True)
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[3]))
    args = parser.parse_args()

    repo = Path(args.repo_root)
    sources = [
        repo / "Nodes/Cpp/docs/BLOCKER_LEDGER.md",
        repo / "Nodes/Cpp/tests/test_script.cpp",
        repo / "Nodes/Cpp/tests/test_native_crypto.cpp",
        repo / "Nodes/Cpp/tests/test_shared_script_corpus.cpp",
    ]
    text = "\n".join(path.read_text(errors="replace") for path in sources if path.exists())
    required = [height for height in REQUIRED_BLOCKERS if height <= args.target]
    missing = [height for height in required if not covered(height, text)]
    if missing:
        print(
            "cpp_target_readiness=failed "
            f"target={args.target} missing_heights={','.join(str(height) for height in missing)}"
        )
        return 1
    print(f"cpp_target_readiness=passed target={args.target} checked_heights={len(required)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
