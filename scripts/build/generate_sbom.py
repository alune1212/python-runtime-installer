#!/usr/bin/env python3
"""Generate a deterministic CycloneDX SBOM from the committed runtime lock."""

from __future__ import annotations

import argparse
import json
import uuid
from datetime import UTC, datetime
from pathlib import Path

from scripts.build.requirements_lock import LockedRequirement, read_lock

ROOT = Path(__file__).resolve().parents[2]
NAMESPACE = uuid.UUID("4fb8d7be-3930-48bb-a40d-7d21d02dcf51")


def _library_component(
    item: "LockedRequirement", scope: str | None = None
) -> dict[str, object]:
    purl = f"pkg:pypi/{item.canonical_name}@{item.version}"
    component: dict[str, object] = {
        "type": "library",
        "bom-ref": f"{purl}?scope={scope}" if scope else purl,
        "name": item.canonical_name,
        "version": item.version,
        "purl": purl,
    }
    if scope:
        component["properties"] = [{"name": "installer:scope", "value": scope}]
    return component


def make_sbom(lock_path: Path, bootstrap_lock_path: Path | None = None) -> dict[str, object]:
    config = json.loads((ROOT / "config" / "product.json").read_text(encoding="utf-8"))
    version = config["product"]["version"]
    python_version = config["target"]["python"]["version"]
    inno = config["build"]["inno_setup"]
    translation = inno["chinese_translation"]
    inno_purl = f"pkg:github/jrsoftware/issrc@{inno['version']}"
    translation_purl = (
        "pkg:github/kira-96/Inno-Setup-Chinese-Simplified-Translation@"
        + translation["commit"]
    )
    root_component: dict[str, object] = {
        "type": "application",
        "bom-ref": "pkg:generic/python-runtime-installer@" + version,
        "name": "Python Runtime Installer",
        "version": version,
        "purl": "pkg:generic/python-runtime-installer@" + version,
    }
    components: list[dict[str, object]] = [
        {
            "type": "platform",
            "bom-ref": "pkg:generic/cpython@" + python_version,
            "name": "CPython",
            "version": python_version,
            "purl": "pkg:generic/cpython@" + python_version,
        },
        {
            "type": "framework",
            "bom-ref": inno_purl,
            "name": "Inno Setup",
            "version": inno["version"],
            "purl": inno_purl,
            "hashes": [{"alg": "SHA-256", "content": inno["sha256"]}],
        },
        {
            "type": "data",
            "bom-ref": translation_purl,
            "name": "Inno Setup Chinese Simplified Translation",
            "version": translation["version"],
            "purl": translation_purl,
            "hashes": [{"alg": "SHA-256", "content": translation["sha256"]}],
            "properties": [{"name": "source:git-commit", "value": translation["commit"]}],
        },
    ]
    components.extend(
        _library_component(item)
        for item in sorted(read_lock(lock_path), key=lambda value: value.canonical_name)
    )
    if bootstrap_lock_path:
        components.extend(
            _library_component(item, scope="bootstrap")
            for item in sorted(
                read_lock(bootstrap_lock_path), key=lambda value: value.canonical_name
            )
        )
    serial = uuid.uuid5(NAMESPACE, f"{version}:cp{python_version}:win_amd64")
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(UTC).isoformat(),
            "component": root_component,
            "properties": [
                {"name": "installer:target", "value": "cp313-win_amd64"},
                {"name": "installer:lock", "value": lock_path.name},
            ],
        },
        "components": components,
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
