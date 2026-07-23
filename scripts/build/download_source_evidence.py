#!/usr/bin/env python3
"""Download hash-verified source archives for packages with redistribution duties."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import urllib.error
import urllib.request
from pathlib import Path

from scripts.build.requirements_lock import locked_versions

ROOT = Path(__file__).resolve().parents[2]


def _download(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "python-runtime-installer/0.1"})
    with urllib.request.urlopen(request, timeout=120) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requirements", type=Path, default=ROOT / "requirements.txt")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build" / "release" / "sources")
    args = parser.parse_args(argv)
    config = json.loads((ROOT / "config" / "product.json").read_text(encoding="utf-8"))
    packages = config["build"]["source_evidence_packages"]
    versions = locked_versions(args.requirements)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    evidence: list[dict[str, str]] = []
    try:
        for package in packages:
            version = versions[package]
            metadata_url = f"https://pypi.org/pypi/{package}/{version}/json"
            with urllib.request.urlopen(metadata_url, timeout=60) as response:
                metadata = json.load(response)
            source_files = [item for item in metadata["urls"] if item["packagetype"] == "sdist"]
            if len(source_files) != 1:
                raise ValueError(f"expected exactly one sdist for {package}=={version}")
            source = source_files[0]
            destination = args.output_dir / source["filename"]
            _download(source["url"], destination)
            digest = hashlib.sha256(destination.read_bytes()).hexdigest()
            expected = source["digests"]["sha256"]
            if digest != expected:
                raise ValueError(f"source archive hash mismatch: {destination.name}")
            evidence.append(
                {
                    "name": package,
                    "version": version,
                    "filename": destination.name,
                    "url": source["url"],
                    "sha256": digest,
                }
            )
        evidence_path = args.output_dir / "source-evidence.json"
        evidence_path.write_text(
            json.dumps(evidence, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
    except (OSError, KeyError, ValueError, urllib.error.URLError) as exc:
        print(f"source evidence error: {exc}", file=sys.stderr)
        return 2
    print(f"source evidence written: {len(evidence)} archives")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
