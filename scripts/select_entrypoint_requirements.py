#!/usr/bin/env python3
"""Create a hash-locked subset for distributions that install command launchers."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import re
import sys
from collections.abc import Iterable, Sequence
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from scripts.build.requirements_lock import LockedRequirement, read_lock  # noqa: E402


class EntrypointSelectionError(RuntimeError):
    """Raised when installed entry points cannot be mapped to the offline locks."""


def _canonical_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def entrypoint_distribution_names(
    distributions: Iterable[importlib.metadata.Distribution] | None = None,
) -> set[str]:
    selected: set[str] = set()
    source = distributions if distributions is not None else importlib.metadata.distributions()
    for distribution in source:
        if not any(
            entry_point.group in {"console_scripts", "gui_scripts"}
            for entry_point in distribution.entry_points
        ):
            continue
        name = distribution.metadata.get("Name")
        if not name:
            raise EntrypointSelectionError("Installed entry-point distribution has no Name")
        selected.add(_canonical_name(name))
    if not selected:
        raise EntrypointSelectionError("No installed command entry points were found")
    return selected


def select_locked_requirements(
    lock_paths: Sequence[Path],
    distributions: Iterable[importlib.metadata.Distribution] | None = None,
) -> list[LockedRequirement]:
    locked: dict[str, LockedRequirement] = {}
    for lock_path in lock_paths:
        for requirement in read_lock(lock_path):
            existing = locked.get(requirement.canonical_name)
            if existing and existing != requirement:
                raise EntrypointSelectionError(
                    f"Conflicting lock entries for {requirement.canonical_name}"
                )
            locked[requirement.canonical_name] = requirement

    selected_names = entrypoint_distribution_names(distributions)
    missing = sorted(selected_names - locked.keys())
    if missing:
        raise EntrypointSelectionError(
            f"Installed entry-point distributions are absent from the locks: {missing}"
        )
    return [locked[name] for name in sorted(selected_names)]


def render_requirements(requirements: Sequence[LockedRequirement]) -> str:
    lines = [
        "# Generated from the verified offline locks for post-promotion launcher relinking.",
    ]
    for requirement in requirements:
        lines.append(f"{requirement.name}=={requirement.version} \\")
        for index, hash_value in enumerate(requirement.hashes):
            suffix = " \\" if index < len(requirement.hashes) - 1 else ""
            lines.append(f"    --hash=sha256:{hash_value}{suffix}")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requirements", type=Path, required=True)
    parser.add_argument("--bootstrap-requirements", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)

    try:
        selected = select_locked_requirements((args.bootstrap_requirements, args.requirements))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(render_requirements(selected), encoding="utf-8")
    except (EntrypointSelectionError, OSError, ValueError) as exc:
        print(f"entry-point requirement selection failed: {exc}", file=sys.stderr)
        return 41

    print(
        json.dumps(
            {
                "count": len(selected),
                "projects": [item.canonical_name for item in selected],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
