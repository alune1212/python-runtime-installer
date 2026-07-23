#!/usr/bin/env python3
"""Create or verify the immutable target payload manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(payload_dir: Path, output: Path) -> dict[str, object]:
    config = json.loads((ROOT / "config" / "product.json").read_text(encoding="utf-8"))
    files: list[dict[str, object]] = []
    for path in sorted(payload_dir.rglob("*")):
        if not path.is_file() or path.resolve() == output.resolve():
            continue
        files.append(
            {
                "path": path.relative_to(payload_dir).as_posix(),
                "size": path.stat().st_size,
                "sha256": sha256(path),
            }
        )
    return {
        "schema_version": 1,
        "installer_version": config["product"]["version"],
        "python_version": config["target"]["python"]["version"],
        "target": "cp313-win_amd64",
        "build_commit": os.environ.get("GITHUB_SHA", "local"),
        "generated_at": datetime.now(UTC).isoformat(),
        "files": files,
    }


def verify_manifest(payload_dir: Path, manifest: dict[str, object]) -> list[str]:
    errors: list[str] = []
    entries = manifest.get("files")
    if not isinstance(entries, list) or not entries:
        return ["manifest has no files"]
    expected_paths: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            errors.append("manifest file entry is not an object")
            continue
        relative = str(entry.get("path", ""))
        if relative in expected_paths:
            errors.append(f"duplicate payload manifest path: {relative}")
            continue
        expected_paths.add(relative)
        candidate = (payload_dir / relative).resolve()
        try:
            candidate.relative_to(payload_dir.resolve())
        except ValueError:
            errors.append(f"manifest path escapes payload root: {relative}")
            continue
        if not candidate.is_file():
            errors.append(f"missing payload file: {relative}")
            continue
        if candidate.stat().st_size != entry.get("size"):
            errors.append(f"payload size mismatch: {relative}")
        if sha256(candidate) != entry.get("sha256"):
            errors.append(f"payload hash mismatch: {relative}")
    actual_paths = {
        path.relative_to(payload_dir).as_posix()
        for path in payload_dir.rglob("*")
        if path.is_file() and path.resolve() != (payload_dir / "payload-manifest.json").resolve()
    }
    for relative in sorted(actual_paths - expected_paths):
        errors.append(f"unexpected unmanifested payload file: {relative}")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload", type=Path, default=ROOT / "build" / "payload")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args(argv)
    output = args.output or args.payload / "payload-manifest.json"
    try:
        if args.verify:
            manifest = json.loads(output.read_text(encoding="utf-8"))
            errors = verify_manifest(args.payload, manifest)
            if errors:
                for error in errors:
                    print(error, file=sys.stderr)
                return 2
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            manifest = build_manifest(args.payload, output)
            output.write_text(
                json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )
    except (OSError, json.JSONDecodeError, KeyError) as exc:
        print(f"payload manifest error: {exc}", file=sys.stderr)
        return 2
    print(f"payload manifest {'valid' if args.verify else 'written'}: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
