from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from scripts.build.validate_config import (
    CONFIG_PATH,
    EXPECTED_DIRECT_REQUIREMENTS,
    ConfigError,
    read_direct_requirements,
    validate_product_config,
)


@pytest.fixture
def config() -> dict[str, object]:
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


def test_committed_configuration_and_direct_requirements_are_valid(
    config: dict[str, object],
) -> None:
    validate_product_config(config, "v0.1.0")
    assert set(read_direct_requirements()) == EXPECTED_DIRECT_REQUIREMENTS
    assert len(read_direct_requirements()) == len(EXPECTED_DIRECT_REQUIREMENTS)


@pytest.mark.parametrize(
    ("path", "value", "message"),
    [
        (("target", "architecture"), "arm64", "only x86_64"),
        (("target", "python", "sha256"), "bad", "Python sha256"),
        (("target", "python", "version"), "3.12.10", "exact 3.13"),
        (("product", "app_id"), "not-a-guid", "uppercase bare GUID"),
        (("build", "inno_setup", "chinese_translation", "sha256"), "bad", "translation sha256"),
    ],
)
def test_invalid_configuration_is_rejected(
    config: dict[str, object], path: tuple[str, ...], value: str, message: str
) -> None:
    candidate = copy.deepcopy(config)
    cursor: dict[str, object] = candidate
    for key in path[:-1]:
        child = cursor[key]
        assert isinstance(child, dict)
        cursor = child
    cursor[path[-1]] = value
    with pytest.raises(ConfigError, match=message):
        validate_product_config(candidate)


def test_release_tag_must_match_product_version(config: dict[str, object]) -> None:
    with pytest.raises(ConfigError, match="does not match"):
        validate_product_config(config, "v0.1.1")


def test_requirements_input_rejects_non_bare_dependencies(tmp_path: Path) -> None:
    source = tmp_path / "requirements.in"
    source.write_text("pandas==2.0\n", encoding="utf-8")
    with pytest.raises(ConfigError, match="bare direct package"):
        read_direct_requirements(source)
