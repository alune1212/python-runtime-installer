#!/usr/bin/env python3
"""Block stable releases until real Windows 10 and 11 acceptance is recorded."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

DESKTOP_PLATFORMS = ("windows_10_x64", "windows_11_x64")


def validate_acceptance(product_version: str, record: dict[str, object]) -> list[str]:
    errors: list[str] = []
    if record.get("schema_version") != 1:
        errors.append("desktop acceptance schema_version must be 1")
    for platform_name in DESKTOP_PLATFORMS:
        value = record.get(platform_name)
        if not isinstance(value, dict):
            errors.append(f"desktop acceptance record is missing {platform_name}")
    if int(product_version.split(".", 1)[0]) < 1:
        return errors
    for platform_name in DESKTOP_PLATFORMS:
        value = record.get(platform_name)
        if not isinstance(value, dict):
            continue
        if value.get("passed") is not True:
            errors.append(f"stable release requires passed acceptance for {platform_name}")
        tested_on = value.get("tested_on")
        evidence = value.get("evidence")
        try:
            if not isinstance(tested_on, str):
                raise ValueError
            date.fromisoformat(tested_on)
        except ValueError:
            errors.append(f"stable release requires an ISO tested_on date for {platform_name}")
        if not isinstance(evidence, str) or not evidence.strip():
            errors.append(f"stable release requires evidence for {platform_name}")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=ROOT / "config" / "product.json")
    parser.add_argument("--record", type=Path, default=ROOT / "config" / "desktop-acceptance.json")
    args = parser.parse_args(argv)
    try:
        product = json.loads(args.config.read_text(encoding="utf-8"))
        record = json.loads(args.record.read_text(encoding="utf-8"))
        errors = validate_acceptance(product["product"]["version"], record)
        if int(product["product"]["version"].split(".", 1)[0]) >= 1:
            for platform_name in DESKTOP_PLATFORMS:
                platform_record = record.get(platform_name)
                if not isinstance(platform_record, dict):
                    continue
                evidence = platform_record.get("evidence")
                if isinstance(evidence, str) and evidence.strip():
                    candidate = (ROOT / evidence).resolve()
                    try:
                        candidate.relative_to(ROOT.resolve())
                    except ValueError:
                        errors.append(
                            f"desktop acceptance evidence escapes the repository: {evidence}"
                        )
                    else:
                        if not candidate.is_file():
                            errors.append(f"desktop acceptance evidence does not exist: {evidence}")
    except (OSError, KeyError, ValueError, json.JSONDecodeError) as exc:
        print(f"desktop acceptance validation error: {exc}", file=sys.stderr)
        return 2
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 2
    print(f"desktop acceptance policy valid for {product['product']['version']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
