#!/usr/bin/env python3
"""Generate third-party notices and license evidence from the exact wheel set."""

from __future__ import annotations

import argparse
import email
import json
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _metadata_from_wheel(wheel: Path) -> tuple[email.message.Message, list[str]]:
    with zipfile.ZipFile(wheel) as archive:
        metadata_names = [
            name for name in archive.namelist() if name.endswith(".dist-info/METADATA")
        ]
        if len(metadata_names) != 1:
            raise ValueError(f"{wheel.name}: expected exactly one METADATA file")
        message = email.message_from_bytes(archive.read(metadata_names[0]))
        license_names = [
            name
            for name in archive.namelist()
            if ".dist-info/licenses/" in name.lower()
            or name.lower().endswith(("/license", "/license.txt", "/copying", "/notice"))
        ]
    return message, sorted(set(license_names))


def generate(wheelhouse: Path, output: Path, licenses_dir: Path) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    if licenses_dir.exists():
        shutil.rmtree(licenses_dir)
    licenses_dir.mkdir(parents=True)
    for wheel in sorted(wheelhouse.glob("*.whl")):
        metadata, license_names = _metadata_from_wheel(wheel)
        name = metadata.get("Name")
        version = metadata.get("Version")
        expression = metadata.get("License-Expression") or metadata.get("License")
        classifiers = metadata.get_all("Classifier", [])
        license_classifiers = [value for value in classifiers if value.startswith("License ::")]
        if not name or not version:
            raise ValueError(f"{wheel.name}: missing Name or Version metadata")
        if not expression and not license_classifiers and not license_names:
            raise ValueError(f"{wheel.name}: missing license metadata and license file")
        project_urls: dict[str, str] = {}
        for value in metadata.get_all("Project-URL", []):
            if "," in value:
                key, url = value.split(",", 1)
                project_urls[key.strip()] = url.strip()
        package_dir = licenses_dir / f"{name}-{version}"
        package_dir.mkdir()
        with zipfile.ZipFile(wheel) as archive:
            for index, member in enumerate(license_names, start=1):
                destination = package_dir / f"{index:02d}-{Path(member).name}"
                destination.write_bytes(archive.read(member))
        records.append(
            {
                "name": name,
                "version": version,
                "license": expression or "; ".join(license_classifiers) or "See bundled files",
                "project_urls": project_urls,
                "license_files": [
                    path.relative_to(output.parent).as_posix()
                    for path in sorted(package_dir.iterdir())
                ],
            }
        )
    if not records:
        raise ValueError(f"no wheels found in {wheelhouse}")
    lines = [
        "THIRD-PARTY NOTICES",
        "===================",
        "",
        "This product redistributes the following independently licensed components.",
        "Full license files are stored in the adjacent licenses directory.",
        "",
    ]
    for record in records:
        lines.extend(
            [
                f"{record['name']} {record['version']}",
                f"License: {record['license']}",
                "Project URLs: " + json.dumps(record["project_urls"], ensure_ascii=False),
                "License files: " + ", ".join(record["license_files"]),
                "",
            ]
        )
    output.write_text("\n".join(lines), encoding="utf-8")
    return records


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--wheelhouse", type=Path, default=ROOT / "build" / "payload" / "wheelhouse"
    )
    parser.add_argument(
        "--output", type=Path, default=ROOT / "build" / "release" / "THIRD_PARTY_NOTICES.txt"
    )
    parser.add_argument("--licenses", type=Path, default=ROOT / "build" / "release" / "licenses")
    args = parser.parse_args(argv)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        records = generate(args.wheelhouse, args.output, args.licenses)
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"notice generation error: {exc}", file=sys.stderr)
        return 2
    print(f"third-party notices written: {len(records)} packages")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
