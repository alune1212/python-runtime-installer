#!/usr/bin/env python3
"""Check release evidence completeness and reject obvious embedded secrets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

from scripts.build.requirements_lock import read_lock

ROOT = Path(__file__).resolve().parents[2]
SECRET_PATTERNS = {
    "GitHub classic token": re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    "GitHub fine-grained token": re.compile(rb"github_pat_[A-Za-z0-9_]{30,}"),
    "AWS access key": re.compile(rb"AKIA[0-9A-Z]{16}"),
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
}


def scan_file(path: Path, secret_values: list[bytes]) -> list[str]:
    data = path.read_bytes()
    errors: list[str] = []
    for label, pattern in SECRET_PATTERNS.items():
        if pattern.search(data):
            errors.append(f"{path.name}: contains {label}")
    for value in secret_values:
        if value and len(value) >= 8 and value in data:
            errors.append(f"{path.name}: contains a configured secret value")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-dir", type=Path, default=ROOT / "build" / "release")
    parser.add_argument("--installer", type=Path, required=True)
    args = parser.parse_args(argv)
    config = json.loads((ROOT / "config" / "product.json").read_text(encoding="utf-8"))
    required = [
        args.installer,
        args.release_dir / "SHA256SUMS.txt",
        args.release_dir / "python-runtime-installer.cdx.json",
        args.release_dir / "THIRD_PARTY_NOTICES.txt",
        args.release_dir / "build-provenance.json",
        args.release_dir / "payload-manifest.json",
        args.release_dir / "PYTHON_LICENSE.txt",
        args.release_dir / "PROJECT_LICENSE.txt",
        args.release_dir
        / f"{config['product']['output_basename']}-{config['product']['version']}-evidence.zip",
        args.release_dir / "sources" / "source-evidence.json",
    ]
    errors = [f"missing release artifact: {path}" for path in required if not path.is_file()]
    secret_values = [
        os.environ[name].encode()
        for name in (
            "WINDOWS_SIGNING_CERTIFICATE_BASE64",
            "WINDOWS_SIGNING_CERTIFICATE_PASSWORD",
            "GITHUB_TOKEN",
        )
        if os.environ.get(name)
    ]
    for path in args.release_dir.rglob("*"):
        if path.is_file():
            errors.extend(scan_file(path, secret_values))
    expected_version = config["product"]["version"]
    for json_path in (
        args.release_dir / "python-runtime-installer.cdx.json",
        args.release_dir / "build-provenance.json",
    ):
        if json_path.is_file() and expected_version not in json_path.read_text(encoding="utf-8"):
            errors.append(
                f"{json_path.name}: does not reference installer version {expected_version}"
            )
    checksum_path = args.release_dir / "SHA256SUMS.txt"
    if checksum_path.is_file() and args.installer.is_file():
        checksum_parts = checksum_path.read_text(encoding="ascii").strip().split()
        actual_hash = hashlib.sha256(args.installer.read_bytes()).hexdigest()
        if checksum_parts != [actual_hash, args.installer.name]:
            errors.append("SHA256SUMS.txt does not match the published installer")
    sbom_path = args.release_dir / "python-runtime-installer.cdx.json"
    if sbom_path.is_file():
        sbom = json.loads(sbom_path.read_text(encoding="utf-8"))
        components = {
            (str(item.get("name")), str(item.get("version"))) for item in sbom.get("components", [])
        }
        expected_components = {
            (item.canonical_name, item.version)
            for lock in (ROOT / "requirements.txt", ROOT / "bootstrap-requirements.txt")
            for item in read_lock(lock)
        }
        expected_components.add(("CPython", config["target"]["python"]["version"]))
        missing = sorted(expected_components - components)
        if missing:
            errors.append(f"SBOM is missing locked components: {missing}")
    provenance_path = args.release_dir / "build-provenance.json"
    if provenance_path.is_file():
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        expected_commit = os.environ.get("GITHUB_SHA")
        expected_run = os.environ.get("GITHUB_RUN_ID")
        if expected_commit and provenance.get("git_commit") != expected_commit:
            errors.append("build provenance commit does not match the workflow commit")
        if expected_run and provenance.get("github_run_id") != expected_run:
            errors.append("build provenance run does not match the workflow run")
    payload_manifest_path = args.release_dir / "payload-manifest.json"
    if payload_manifest_path.is_file():
        payload_manifest = json.loads(payload_manifest_path.read_text(encoding="utf-8"))
        if payload_manifest.get("installer_version") != expected_version:
            errors.append("payload manifest installer version does not match product configuration")
        if payload_manifest.get("build_commit") != os.environ.get("GITHUB_SHA", "local"):
            errors.append("payload manifest commit does not match the build commit")
    evidence_path = args.release_dir / "sources" / "source-evidence.json"
    if evidence_path.is_file():
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        evidence_names = {item.get("name") for item in evidence}
        missing_sources = set(config["build"]["source_evidence_packages"]) - evidence_names
        if missing_sources:
            errors.append(f"source evidence is missing configured packages: {missing_sources}")
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 2
    print(f"release evidence valid: {args.release_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
