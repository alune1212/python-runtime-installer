#!/usr/bin/env python3
"""Fail when source files contain common credential material."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from scripts.build.scan_release import scan_file

ROOT = Path(__file__).resolve().parents[2]
IGNORED_TOP_LEVEL = {".git", ".venv", "build"}
IGNORED_PARTS = {".pytest_cache", ".ruff_cache", "__pycache__"}
SECRET_SUFFIXES = {".p12", ".pfx", ".key", ".pem"}


def scan_repository(root: Path) -> list[str]:
    errors: list[str] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if relative.parts[0] in IGNORED_TOP_LEVEL or any(
            part in IGNORED_PARTS for part in relative.parts
        ):
            continue
        if path.suffix.lower() in SECRET_SUFFIXES:
            errors.append(f"secret-bearing file type is forbidden: {path.relative_to(root)}")
            continue
        try:
            errors.extend(scan_file(path, []))
        except OSError as exc:
            errors.append(f"cannot scan {path.relative_to(root)}: {exc}")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    errors = scan_repository(args.root)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 2
    print(f"repository secret scan passed: {args.root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
