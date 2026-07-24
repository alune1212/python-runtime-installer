from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import pytest

from scripts.select_entrypoint_requirements import (
    EntrypointSelectionError,
    render_requirements,
    select_locked_requirements,
)

HASH_A = "a" * 64
HASH_B = "b" * 64


@dataclass
class EntryPoint:
    group: str


class Distribution:
    def __init__(self, name: str | None, groups: tuple[str, ...]) -> None:
        self.metadata = {} if name is None else {"Name": name}
        self.entry_points = [EntryPoint(group) for group in groups]


def write_lock(path: Path, entries: list[tuple[str, str, str]]) -> None:
    path.write_text(
        "\n".join(
            f"{name}=={version} --hash=sha256:{hash_value}" for name, version, hash_value in entries
        )
        + "\n",
        encoding="utf-8",
    )


def test_selects_only_locked_entrypoint_distributions(tmp_path: Path) -> None:
    bootstrap = tmp_path / "bootstrap.txt"
    requirements = tmp_path / "requirements.txt"
    write_lock(bootstrap, [("pip", "26.1.2", HASH_A)])
    write_lock(
        requirements,
        [("Flask", "3.1.3", HASH_A), ("numpy", "2.5.1", HASH_B)],
    )
    distributions = [
        Distribution("pip", ("console_scripts",)),
        Distribution("Flask", ("console_scripts",)),
        Distribution("numpy", ()),
    ]

    selected = select_locked_requirements((bootstrap, requirements), distributions=distributions)
    assert [item.canonical_name for item in selected] == ["flask", "pip"]
    rendered = render_requirements(selected)
    assert "Flask==3.1.3" in rendered
    assert "pip==26.1.2" in rendered
    assert "numpy==2.5.1" not in rendered
    assert f"--hash=sha256:{HASH_A}" in rendered


def test_rejects_unlocked_entrypoint_distribution(tmp_path: Path) -> None:
    bootstrap = tmp_path / "bootstrap.txt"
    requirements = tmp_path / "requirements.txt"
    write_lock(bootstrap, [("pip", "26.1.2", HASH_A)])
    write_lock(requirements, [("numpy", "2.5.1", HASH_B)])

    with pytest.raises(EntrypointSelectionError, match="absent from the locks"):
        select_locked_requirements(
            (bootstrap, requirements),
            distributions=[Distribution("unlocked-tool", ("console_scripts",))],
        )


def test_rejects_conflicting_entries_across_locks(tmp_path: Path) -> None:
    bootstrap = tmp_path / "bootstrap.txt"
    requirements = tmp_path / "requirements.txt"
    write_lock(bootstrap, [("pip", "26.1.2", HASH_A)])
    write_lock(requirements, [("PIP", "26.1.3", HASH_B)])

    with pytest.raises(EntrypointSelectionError, match="Conflicting"):
        select_locked_requirements(
            (bootstrap, requirements),
            distributions=[Distribution("pip", ("console_scripts",))],
        )


def test_rejects_missing_distribution_name_and_empty_entrypoint_set(tmp_path: Path) -> None:
    bootstrap = tmp_path / "bootstrap.txt"
    requirements = tmp_path / "requirements.txt"
    write_lock(bootstrap, [("pip", "26.1.2", HASH_A)])
    write_lock(requirements, [("numpy", "2.5.1", HASH_B)])

    with pytest.raises(EntrypointSelectionError, match="has no Name"):
        select_locked_requirements(
            (bootstrap, requirements),
            distributions=[Distribution(None, ("gui_scripts",))],
        )
    with pytest.raises(EntrypointSelectionError, match="No installed command"):
        select_locked_requirements(
            (bootstrap, requirements),
            distributions=[Distribution("numpy", ())],
        )
