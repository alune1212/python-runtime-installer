#!/usr/bin/env python3
"""Validate the pinned product configuration and direct dependency contract."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = ROOT / "config" / "product.json"
REQUIREMENTS_IN = ROOT / "requirements.in"
EXPECTED_DIRECT_REQUIREMENTS = {
    "beautifulsoup4",
    "faker",
    "flask",
    "matplotlib",
    "mysql-connector-python",
    "networkx",
    "numpy",
    "openpyxl",
    "paho-mqtt",
    "pandas",
    "scikit-learn",
    "seaborn",
    "selenium",
    "webdriver-manager",
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SEMVER_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
PYTHON_VERSION_RE = re.compile(r"^3\.13\.\d+$")
APP_ID_RE = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")


class ConfigError(ValueError):
    """Raised when a pinned configuration contract is invalid."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ConfigError(message)


def _load_json(path: Path) -> dict[str, object]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"Cannot load {path}: {exc}") from exc


def _normalize_package_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def read_direct_requirements(path: Path = REQUIREMENTS_IN) -> list[str]:
    result: list[str] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        _require(
            not any(token in line for token in ("==", ">", "<", "@", ";", "[")),
            f"requirements.in must contain bare direct package names: {line}",
        )
        result.append(_normalize_package_name(line))
    return result


def validate_product_config(config: dict[str, object], tag: str | None = None) -> None:
    _require(config.get("schema_version") == 1, "schema_version must be 1")
    product = config.get("product")
    target = config.get("target")
    build = config.get("build")
    _require(isinstance(product, dict), "product must be an object")
    _require(isinstance(target, dict), "target must be an object")
    _require(isinstance(build, dict), "build must be an object")
    assert isinstance(product, dict) and isinstance(target, dict) and isinstance(build, dict)

    version = product.get("version")
    _require(
        isinstance(version, str) and SEMVER_RE.fullmatch(version) is not None,
        "product.version must be semantic X.Y.Z",
    )
    _require(product.get("name") == "Python Runtime Installer", "unexpected product.name")
    _require(product.get("publisher") == "Alune", "unexpected product.publisher")
    _require(
        APP_ID_RE.fullmatch(str(product.get("app_id", ""))) is not None,
        "product.app_id must be an uppercase bare GUID",
    )
    _require(
        product.get("install_dir_relative") == "Programs\\Python Runtime Installer",
        "install_dir_relative must remain fixed",
    )
    _require(
        product.get("registry_path") == "Software\\Alune\\Python Runtime Installer",
        "registry_path must remain fixed",
    )
    project = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    _require(
        project["project"]["version"] == version,
        "pyproject project.version does not match product.version",
    )

    _require(target.get("architecture") == "x86_64", "only x86_64 is supported")
    _require(
        target.get("minimum_free_bytes") == 2 * 1024**3, "minimum_free_bytes must be exactly 2 GiB"
    )
    _require(
        target.get("operating_systems") == ["Windows 10", "Windows 11"],
        "target operating systems must be Windows 10 and Windows 11",
    )

    python = target.get("python")
    _require(isinstance(python, dict), "target.python must be an object")
    assert isinstance(python, dict)
    python_version = python.get("version")
    _require(
        isinstance(python_version, str) and PYTHON_VERSION_RE.fullmatch(python_version) is not None,
        "target Python must be an exact 3.13 patch release",
    )
    _require(python.get("implementation") == "CPython", "only CPython is supported")
    _require(
        python.get("filename") == f"python-{python_version}-amd64.exe",
        "Python filename does not match version",
    )
    _require(
        SHA256_RE.fullmatch(str(python.get("sha256", ""))) is not None,
        "Python sha256 must be 64 lowercase hexadecimal characters",
    )
    _require(
        SHA256_RE.fullmatch(str(python.get("license_sha256", ""))) is not None,
        "Python license_sha256 must be 64 lowercase hexadecimal characters",
    )
    python_url = str(python.get("url", ""))
    _require(urlparse(python_url).scheme == "https", "Python URL must use HTTPS")
    _require(
        python_url.endswith(str(python.get("filename"))),
        "Python URL does not end with configured filename",
    )
    _require(
        urlparse(str(python.get("license_url", ""))).scheme == "https",
        "Python license URL must use HTTPS",
    )

    inno = build.get("inno_setup")
    _require(isinstance(inno, dict), "build.inno_setup must be an object")
    assert isinstance(inno, dict)
    _require(
        SHA256_RE.fullmatch(str(inno.get("sha256", ""))) is not None,
        "Inno Setup sha256 must be 64 lowercase hexadecimal characters",
    )
    _require(urlparse(str(inno.get("url", ""))).scheme == "https", "Inno Setup URL must use HTTPS")
    _require(
        str(inno.get("url", "")).endswith(str(inno.get("filename", ""))),
        "Inno Setup URL does not end with configured filename",
    )
    _require(build.get("uv_version") == "0.11.29", "build.uv_version must stay pinned")
    _require(
        project["tool"]["uv"]["required-version"] == f"=={build['uv_version']}",
        "pyproject UV requirement does not match build.uv_version",
    )
    _require(build.get("windows_runner") == "windows-2025", "unexpected Windows runner")
    _require(
        inno.get("filename") == f"innosetup-{inno.get('version')}.exe",
        "Inno Setup filename does not match its version",
    )

    if tag:
        _require(tag == f"v{version}", f"tag {tag!r} does not match product version v{version}")

    direct = read_direct_requirements()
    _require(len(direct) == len(set(direct)), "requirements.in contains duplicates")
    _require(
        set(direct) == EXPECTED_DIRECT_REQUIREMENTS,
        "requirements.in does not exactly match the approved direct dependency set",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=CONFIG_PATH)
    parser.add_argument("--tag", help="Optional release tag to validate")
    args = parser.parse_args(argv)
    try:
        validate_product_config(_load_json(args.config), args.tag)
    except ConfigError as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2
    print(f"configuration valid: {args.config}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
