#!/usr/bin/env python3
"""Generate the Windows CPython 3.13 hash lock using the pinned uv executable."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from scripts.build.requirements_lock import LockError, read_lock
from scripts.build.validate_config import validate_product_config

ROOT = Path(__file__).resolve().parents[2]


def build_command(
    config: dict[str, object], input_path: Path, output: Path, upgrade: bool
) -> list[str]:
    target = config["target"]
    assert isinstance(target, dict)
    python = target["python"]
    assert isinstance(python, dict)
    command = [
        "uv",
        "pip",
        "compile",
        str(input_path),
        "--output-file",
        str(output),
        "--python-version",
        str(python["version"]),
        "--python-platform",
        "x86_64-pc-windows-msvc",
        "--only-binary",
        ":all:",
        "--generate-hashes",
        "--prerelease",
        "disallow",
        "--resolution",
        "highest",
        "--custom-compile-command",
        "uv run python -m scripts.build.lock_requirements",
        "--default-index",
        "https://pypi.org/simple",
    ]
    if upgrade:
        command.append("--upgrade")
    return command


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "requirements.txt")
    parser.add_argument(
        "--bootstrap-output", type=Path, default=ROOT / "bootstrap-requirements.txt"
    )
    parser.add_argument("--upgrade", action="store_true")
    parser.add_argument("--check", action="store_true", help="Validate without regenerating")
    args = parser.parse_args(argv)
    config = json.loads((ROOT / "config" / "product.json").read_text(encoding="utf-8"))
    try:
        validate_product_config(config, os.environ.get("RELEASE_TAG") or None)
        if not args.check:
            subprocess.run(
                build_command(config, ROOT / "requirements.in", args.output, args.upgrade),
                cwd=ROOT,
                check=True,
            )
            subprocess.run(
                build_command(
                    config,
                    ROOT / "bootstrap-requirements.in",
                    args.bootstrap_output,
                    args.upgrade,
                ),
                cwd=ROOT,
                check=True,
            )
        locked = read_lock(args.output)
        bootstrap_locked = read_lock(args.bootstrap_output)
    except (LockError, ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"requirements lock error: {exc}", file=sys.stderr)
        return 2
    print(
        "requirements locks valid: "
        f"{len(locked)} runtime packages and {len(bootstrap_locked)} bootstrap packages"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
