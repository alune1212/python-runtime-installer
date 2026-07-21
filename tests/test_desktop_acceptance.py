from __future__ import annotations

from scripts.build.validate_desktop_acceptance import validate_acceptance

EMPTY_RECORD = {
    "schema_version": 1,
    "windows_10_x64": {"passed": False, "tested_on": None, "evidence": None},
    "windows_11_x64": {"passed": False, "tested_on": None, "evidence": None},
}


def test_prerelease_does_not_claim_real_device_acceptance() -> None:
    assert validate_acceptance("0.1.0", EMPTY_RECORD) == []


def test_stable_release_requires_both_real_desktop_records() -> None:
    errors = validate_acceptance("1.0.0", EMPTY_RECORD)
    assert any("windows_10_x64" in error for error in errors)
    assert any("windows_11_x64" in error for error in errors)


def test_stable_release_accepts_complete_evidence() -> None:
    record = {
        "schema_version": 1,
        "windows_10_x64": {
            "passed": True,
            "tested_on": "2026-07-21",
            "evidence": "docs/acceptance/windows-10-2026-07-21.md",
        },
        "windows_11_x64": {
            "passed": True,
            "tested_on": "2026-07-21",
            "evidence": "docs/acceptance/windows-11-2026-07-21.md",
        },
    }
    assert validate_acceptance("1.0.0", record) == []
