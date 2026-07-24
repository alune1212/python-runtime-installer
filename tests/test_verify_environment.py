from __future__ import annotations

import json
from pathlib import Path

import pytest

from scripts import verify_environment as verifier


def test_import_map_covers_exactly_the_approved_direct_packages() -> None:
    assert set(verifier.IMPORT_NAMES) == {
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


def test_browser_packages_are_import_only() -> None:
    source = Path(verifier.__file__).read_text(encoding="utf-8")
    assert 'importlib.import_module("selenium")' in source
    assert 'importlib.import_module("webdriver_manager")' in source
    assert "ChromeDriverManager" not in source
    assert "GeckoDriverManager" not in source
    assert "webdriver.Chrome" not in source


def test_run_verification_success_is_deterministic(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    calls: list[str] = []
    monkeypatch.setattr(
        verifier, "verify_runtime", lambda expected, executable: calls.append("runtime")
    )
    monkeypatch.setattr(verifier, "verify_packages", lambda path: {"pandas": "1.0"})
    monkeypatch.setattr(verifier, "verify_bootstrap", lambda path: {"pip": "1.0"})
    monkeypatch.setattr(verifier, "verify_entrypoint_launchers", lambda: calls.append("launchers"))
    monkeypatch.setattr(verifier, "verify_immutable_distribution_set", lambda *args: None)

    def smoke() -> None:
        calls.append("smoke")

    result = verifier.run_verification(
        tmp_path / "requirements.txt",
        tmp_path / "bootstrap-requirements.txt",
        "3.13.14",
        "C:/应用 程序/venv/Scripts/python.exe",
        None,
        smoke_tests=(smoke,),
    )
    assert result["status"] == "passed"
    assert result["packages"] == {"pandas": "1.0"}
    assert result["bootstrap_tooling"] == {"pip": "1.0"}
    assert calls == ["runtime", "launchers", "smoke"]


@pytest.mark.parametrize("failure", ["version drift", "missing import", "pip conflict"])
def test_main_returns_stable_code_for_required_failure(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, failure: str
) -> None:
    monkeypatch.setattr(
        verifier,
        "run_verification",
        lambda *args, **kwargs: (_ for _ in ()).throw(verifier.VerificationError(failure)),
    )
    assert (
        verifier.main(
            [
                "--requirements",
                str(tmp_path / "requirements.txt"),
                "--bootstrap-requirements",
                str(tmp_path / "bootstrap.txt"),
                "--expected-python",
                "3.13.14",
            ]
        )
        == 40
    )


def test_manifest_alignment_includes_bootstrap(tmp_path: Path) -> None:
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "python_version": "3.13.14",
                "python_executable": verifier.sys.executable,
                "verification_status": "passed",
                "packages": {"pandas": "1.0"},
                "bootstrap_tooling": {"pip": "1.0"},
            }
        ),
        encoding="utf-8",
    )
    verifier.verify_manifest(manifest, {"pandas": "1.0"}, {"pip": "1.0"}, "3.13.14")
    with pytest.raises(verifier.VerificationError, match="bootstrap"):
        verifier.verify_manifest(manifest, {"pandas": "1.0"}, {"pip": "2.0"}, "3.13.14")


def test_immutable_distribution_set_rejects_custom_packages(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Distribution:
        def __init__(self, name: str) -> None:
            self.metadata = {"Name": name}

    monkeypatch.setattr(
        verifier.importlib.metadata,
        "distributions",
        lambda: [Distribution("pandas"), Distribution("pip"), Distribution("custom-package")],
    )
    with pytest.raises(verifier.VerificationError, match="custom-package"):
        verifier.verify_immutable_distribution_set({"pandas": "1.0"}, {"pip": "1.0"})


def test_entrypoint_launcher_must_target_current_interpreter(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    scripts = tmp_path / "Scripts"
    scripts.mkdir()
    executable = scripts / "python.exe"
    executable.write_bytes(b"python")
    launcher = scripts / "example.exe"
    monkeypatch.setattr(verifier.sys, "executable", str(executable))
    monkeypatch.setattr(verifier, "_entrypoint_launchers", lambda: [("example", executable)])

    launcher.write_bytes(b'MZ...#!"' + verifier.os.fsencode(executable) + b'"\nPK')
    verifier.verify_entrypoint_launchers()

    launcher.write_bytes(b"MZ...#!" + verifier.os.fsencode(executable) + b"\nPK")
    verifier.verify_entrypoint_launchers()

    launcher.write_bytes(b'MZ...#!"C:\\staging\\python.exe"\nPK')
    with pytest.raises(verifier.VerificationError, match="wrong interpreter"):
        verifier.verify_entrypoint_launchers()


def test_entrypoint_launchers_include_pip_variants_and_gui_target(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    class EntryPoint:
        def __init__(self, name: str, group: str) -> None:
            self.name = name
            self.group = group

    class Distribution:
        def __init__(self, name: str, entry_points: list[EntryPoint]) -> None:
            self.metadata = {"Name": name}
            self.entry_points = entry_points

    executable = tmp_path / "Scripts" / "python.exe"
    monkeypatch.setattr(verifier.sys, "executable", str(executable))
    monkeypatch.setattr(
        verifier.importlib.metadata,
        "distributions",
        lambda: [
            Distribution("pip", [EntryPoint("pip", "console_scripts")]),
            Distribution("gui-tool", [EntryPoint("gui-tool", "gui_scripts")]),
        ],
    )

    launchers = dict(verifier._entrypoint_launchers())
    assert launchers["pip"] == executable
    assert launchers[f"pip{verifier.sys.version_info.major}"] == executable
    assert launchers[f"pip{verifier.sys.version_info.major}.{verifier.sys.version_info.minor}"] == (
        executable
    )
    assert launchers["gui-tool"] == executable.with_name("pythonw.exe")


@pytest.mark.parametrize(
    "unsafe_name",
    ["..\\unsafe", "../unsafe", "C:unsafe", "unsafe.", "NUL"],
)
def test_entrypoint_launcher_rejects_unsafe_name(
    monkeypatch: pytest.MonkeyPatch, unsafe_name: str
) -> None:
    class EntryPoint:
        def __init__(self, name: str) -> None:
            self.name = name
            self.group = "console_scripts"

    class Distribution:
        def __init__(self) -> None:
            self.metadata = {"Name": "unsafe-tool"}
            self.entry_points = [EntryPoint(unsafe_name)]

    monkeypatch.setattr(verifier.importlib.metadata, "distributions", lambda: [Distribution()])
    with pytest.raises(verifier.VerificationError, match="Unsafe"):
        verifier._entrypoint_launchers()


def test_entrypoint_launcher_must_exist(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    executable = tmp_path / "Scripts" / "python.exe"
    executable.parent.mkdir()
    executable.write_bytes(b"python")
    monkeypatch.setattr(verifier.sys, "executable", str(executable))
    monkeypatch.setattr(verifier, "_entrypoint_launchers", lambda: [("missing", executable)])

    with pytest.raises(verifier.VerificationError, match="missing"):
        verifier.verify_entrypoint_launchers()
