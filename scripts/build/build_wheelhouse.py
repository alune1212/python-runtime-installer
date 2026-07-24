#!/usr/bin/env python3
"""Download the exact binary wheel set for the active Windows interpreter."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from scripts.build.requirements_lock import LockError, read_lock

ROOT = Path(__file__).resolve().parents[2]


def verify_wheelhouse(lock_path: Path, wheelhouse: Path) -> list[str]:
    locked = read_lock(lock_path)
    wheels = [path.name.lower() for path in wheelhouse.glob("*.whl")]
    missing: list[str] = []
    for item in locked:
        prefix = f"{item.canonical_name.replace('-', '_')}-{item.version}".lower()
        if not any(
            wheel.startswith(prefix) or wheel.replace("-", "_").startswith(prefix)
            for wheel in wheels
        ):
            missing.append(f"{item.canonical_name}=={item.version}")
    return missing


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requirements", type=Path, default=ROOT / "requirements.txt")
    parser.add_argument(
        "--bootstrap-requirements",
        type=Path,
        default=ROOT / "bootstrap-requirements.txt",
    )
    parser.add_argument(
        "--wheelhouse", type=Path, default=ROOT / "build" / "payload" / "wheelhouse"
    )
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args(argv)
    try:
        read_lock(args.requirements)
        read_lock(args.bootstrap_requirements)
        if not args.verify_only:
            if args.wheelhouse.exists():
                shutil.rmtree(args.wheelhouse)
            args.wheelhouse.mkdir(parents=True)
            for lock_path in (args.bootstrap_requirements, args.requirements):
                subprocess.run(
                    [
                        args.python,
                        "-m",
                        "pip",
                        "download",
                        "--dest",
                        str(args.wheelhouse),
                        "--require-hashes",
                        "--only-binary=:all:",
                        "--no-deps",
                        "--index-url",
                        "https://pypi.org/simple",
                        "--requirement",
                        str(lock_path),
                    ],
                    cwd=ROOT,
                    check=True,
                )
        missing = verify_wheelhouse(args.bootstrap_requirements, args.wheelhouse)
        missing.extend(verify_wheelhouse(args.requirements, args.wheelhouse))
    except (LockError, OSError, subprocess.CalledProcessError) as exc:
        print(f"wheelhouse build error: {exc}", file=sys.stderr)
        return 2
    if missing:
        print("wheelhouse is missing locked packages: " + ", ".join(missing), file=sys.stderr)
        return 2
    print(f"wheelhouse valid: {len(list(args.wheelhouse.glob('*.whl')))} wheels")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
