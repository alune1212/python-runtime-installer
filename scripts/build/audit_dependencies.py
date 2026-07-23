#!/usr/bin/env python3
"""Run pip-audit with validated, time-bounded vulnerability exceptions."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import date
from pathlib import Path

from scripts.build.validate_vulnerability_exceptions import validate_exceptions

ROOT = Path(__file__).resolve().parents[2]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requirements", type=Path, default=ROOT / "requirements.txt")
    parser.add_argument(
        "--bootstrap-requirements",
        type=Path,
        default=ROOT / "bootstrap-requirements.txt",
    )
    parser.add_argument(
        "--exceptions", type=Path, default=ROOT / "config" / "vulnerability-exceptions.json"
    )
    parser.add_argument(
        "--schema", type=Path, default=ROOT / "config" / "vulnerability-exceptions.schema.json"
    )
    parser.add_argument("--output", type=Path, default=ROOT / "build" / "audit.json")
    args = parser.parse_args(argv)
    errors = validate_exceptions(args.exceptions, args.schema, date.today())
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 2
    exceptions = json.loads(args.exceptions.read_text(encoding="utf-8"))["exceptions"]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "pip-audit",
        "--no-deps",
        "--disable-pip",
        "--require-hashes",
    ]
    for lock_path in (args.requirements, args.bootstrap_requirements):
        command.extend(["--requirement", str(lock_path)])
    command.extend(["--format", "json", "--output", str(args.output), "--strict"])
    for entry in exceptions:
        command.extend(["--ignore-vuln", entry["id"]])
    completed = subprocess.run(command, cwd=ROOT, check=False)
    if completed.returncode:
        print("dependency audit failed", file=sys.stderr)
        return completed.returncode
    print(f"dependency audit passed: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
