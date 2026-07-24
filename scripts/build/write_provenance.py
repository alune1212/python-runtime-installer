#!/usr/bin/env python3
"""Write release build provenance from pinned configuration and CI context."""

from __future__ import annotations

import argparse
import json
import os
import platform
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output", type=Path, default=ROOT / "build" / "release" / "build-provenance.json"
    )
    args = parser.parse_args(argv)
    config = json.loads((ROOT / "config" / "product.json").read_text(encoding="utf-8"))
    translation = config["build"]["inno_setup"]["chinese_translation"]
    provenance = {
        "schema_version": 1,
        "generated_at": datetime.now(UTC).isoformat(),
        "installer_version": config["product"]["version"],
        "python_version": config["target"]["python"]["version"],
        "target": "cp313-win_amd64",
        "uv_version": config["build"]["uv_version"],
        "inno_setup_version": config["build"]["inno_setup"]["version"],
        "inno_setup_sha256": config["build"]["inno_setup"]["sha256"],
        "inno_setup_translation_version": translation["version"],
        "inno_setup_translation_commit": translation["commit"],
        "inno_setup_translation_sha256": translation["sha256"],
        "git_commit": os.environ.get("GITHUB_SHA", "local"),
        "github_repository": os.environ.get(
            "GITHUB_REPOSITORY", "alune1212/python-runtime-installer"
        ),
        "github_run_id": os.environ.get("GITHUB_RUN_ID", "local"),
        "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "local"),
        "builder_os": platform.platform(),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(provenance, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"provenance written: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
