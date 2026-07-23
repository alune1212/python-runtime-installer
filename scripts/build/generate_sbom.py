#!/usr/bin/env python3
"""Generate a deterministic CycloneDX SBOM from the committed runtime lock."""

from __future__ import annotations

import argparse
import json
import uuid
from datetime import UTC, datetime
from pathlib import Path

from scripts.build.requirements_lock import read_lock

ROOT = Path(__file__).resolve().parents[2]
NAMESPACE = uuid.UUID("4fb8d7be-3930-48bb-a40d-7d21d02dcf51")


def make_sbom(lock_path: Path, bootstrap_lock_path: Path | None = None) -> dict[str, object]:
    config = json.loads((ROOT / "config" / "product.json").read_text(encoding="utf-8"))
    version = config["product"]["version"]
    python_version = config["target"]["python"]["version"]
    inno = config["build"]["inno_setup"]
    translation = inno["chinese_translation"]
    components: list[dict[str, object]] = [
        {
            "type": "application",
            "bom-ref": "pkg:generic/python-runtime-installer@" + version,
            "name": "Python Runtime Installer",
            "version": version,
            "purl": "pkg:generic/python-runtime-installer@" + version,
        },
        {
            "type": "platform",
            "bom-ref": "pkg:generic/cpython@" + python_version,
            "name": "CPython",
            "version": python_version,
            "purl": "pkg:generic/cpython@" + python_version,
        },
        {
            "type": "framework",
            "bom-ref": f"pkg:github/jrsoftware/issrc@{inno['version']}",
            "name": "Inno Setup",
            "version": inno["version"],
            "purl": f"pkg:github/jrsoftware/issrc@{inno['version']}",
            "hashes": [{"alg": "SHA-256", "content": inno["sha256"]}],
        },
        {
            "type": "data",
            "bom-ref": (
                "pkg:github/kira-96/Inno-Setup-Chinese-Simplified-Translation@"
                + translation["commit"]
            ),
            "name": "Inno Setup Chinese Simplified Translation",
            "version": translation["version"],
            "purl": (
                "pkg:github/kira-96/Inno-Setup-Chinese-Simplified-Translation@"
                + translation["commit"]
            ),
            "hashes": [{"alg": "SHA-256", "content": translation["sha256"]}],
            "properties": [{"name": "source:git-commit", "value": translation["commit"]}],
        },
    ]
    for item in sorted(read_lock(lock_path), key=lambda value: value.canonical_name):
        components.append(
            {
                "type": "library",
                "bom-ref": f"pkg:pypi/{item.canonical_name}@{item.version}",
                "name": item.canonical_name,
                "version": item.version,
                "purl": f"pkg:pypi/{item.canonical_name}@{item.version}",
            }
        )
    if bootstrap_lock_path:
        for item in sorted(read_lock(bootstrap_lock_path), key=lambda value: value.canonical_name):
            components.append(
                {
                    "type": "library",
                    "bom-ref": f"pkg:pypi/{item.canonical_name}@{item.version}?scope=bootstrap",
                    "name": item.canonical_name,
                    "version": item.version,
                    "purl": f"pkg:pypi/{item.canonical_name}@{item.version}",
                    "properties": [{"name": "installer:scope", "value": "bootstrap"}],
                }
            )
    serial = uuid.uuid5(NAMESPACE, f"{version}:cp{python_version}:win_amd64")
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(UTC).isoformat(),
            "component": components[0],
            "properties": [
                {"name": "installer:target", "value": "cp313-win_amd64"},
                {"name": "installer:lock", "value": lock_path.name},
            ],
        },
        "components": components[1:],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requirements", type=Path, default=ROOT / "requirements.txt")
    parser.add_argument(
        "--bootstrap-requirements",
        type=Path,
        default=ROOT / "bootstrap-requirements.txt",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "build" / "release" / "python-runtime-installer.cdx.json",
    )
    args = parser.parse_args(argv)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(
            make_sbom(args.requirements, args.bootstrap_requirements),
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"SBOM written: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
