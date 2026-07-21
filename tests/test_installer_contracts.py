from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def test_target_install_is_offline_hash_checked_and_transactional() -> None:
    script = read("scripts/windows/Install-Runtime.ps1")
    for required in (
        "--no-index",
        "--find-links",
        "--require-hashes",
        "--no-deps",
        "'.staging\\'",
        "'.previous-'",
        "Move-Item -LiteralPath $stageVenv -Destination $activeRoot",
        "Publish-DiscoveryMetadata",
        "Downgrade blocked",
    ):
        assert required in script
    assert "Invoke-WebRequest" not in script
    assert "http://" not in script and "https://" not in script


def test_private_runtime_never_changes_path_or_machine_scope() -> None:
    module = read("scripts/windows/RuntimeInstaller.psm1")
    for required in (
        "InstallAllUsers=0",
        "Include_launcher=0",
        "AssociateFiles=0",
        "Shortcuts=0",
        "PrependPath=0",
        "AppendPath=0",
    ):
        assert required in module
    assert "setx" not in module.lower()


def test_inno_contract_is_per_user_bilingual_silent_and_start_menu_only() -> None:
    project = read("installer/python-runtime-installer.iss")
    for required in (
        "PrivilegesRequired=lowest",
        "DefaultDirName={localappdata}\\Programs\\Python Runtime Installer",
        'Name: "english"',
        'Name: "chinesesimplified"',
        "/FORCEBUNDLED",
        "ExecutionPolicy Bypass",
        "ChangesEnvironment=no",
        "RestartApplications=no",
        "CompareSemVer(InstalledVersion, '{#ProductVersion}') > 0",
        "ManagedExitCode := 21",
    ):
        assert required in project
    assert "{commondesktop}" not in project
    assert "{userdesktop}" not in project


def test_inno_build_tool_install_is_portable_and_user_scoped() -> None:
    script = read("scripts/build/Install-InnoSetup.ps1")
    for required in ("/CURRENTUSER", "/PORTABLE=1", "/NOICONS"):
        assert required in script


def test_lifecycle_script_contains_rollback_and_ownership_guards() -> None:
    install = read("scripts/windows/Install-Runtime.ps1")
    uninstall = read("scripts/windows/Uninstall-Runtime.ps1")
    assert "previousManifestPath" in install
    assert "Get-DiscoveryMetadataSnapshot" in install
    assert "Restore-DiscoveryMetadata" in install
    assert "runtime_ownership = $runtimeOwnership" in install
    assert "runtime_ownership -eq 'private'" in uninstall
    assert "retained logs were preserved" in uninstall
    assert "Move-Item -LiteralPath $previousRoot -Destination" in install
    assert "$activationCommitted = $true" in install
    assert "Write-InstallStatus -Value 'downgrade-blocked'" in install
    assert "exit 21" in install


def test_end_to_end_contract_covers_healthy_repair_drift_and_reuse() -> None:
    test_script = read("scripts/build/Test-Installer.ps1")
    for required in (
        "/FORCEBUNDLED",
        "healthyManifestHash",
        "custom_drift-1.0.dist-info",
        "runtime_ownership -eq 'reused'",
        "Reused CPython was removed by uninstall",
        "failed_staging",
        "installer-e2e-evidence.json",
        "Test-PathsUnchanged",
        "verification_checks",
        "private_python_removed",
    ):
        assert required in test_script


def test_generated_inno_config_is_current_and_app_id_is_escaped() -> None:
    generated = read("installer/generated-config.iss")
    assert '#define AppId "{{779F23D1-372D-4A68-AD18-80C5116A8B50}"' in generated
    assert '#define ProductVersion "0.1.0"' in generated


def test_all_workflow_actions_are_pinned_to_full_commit_shas() -> None:
    workflows = list((ROOT / ".github" / "workflows").glob("*.yml"))
    assert {path.name for path in workflows} == {
        "build-installer.yml",
        "ci.yml",
        "dependency-update.yml",
    }
    for workflow in workflows:
        uses = re.findall(r"^\s*uses:\s*([^\s]+)", workflow.read_text(encoding="utf-8"), re.M)
        assert uses
        for reference in uses:
            assert re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", reference), (workflow, reference)


def test_monthly_refresh_is_review_only_and_skips_unchanged_output() -> None:
    workflow = read(".github/workflows/dependency-update.yml")
    assert "No compatible dependency updates were found." in workflow
    assert "if: steps.changes.outputs.changed == 'true'" in workflow
    assert "gh pr create" in workflow
    assert "gh pr merge" not in workflow
    assert "gh release" not in workflow
    assert "git tag" not in workflow


def test_release_only_runs_for_tags_after_the_build_gate() -> None:
    workflow = read(".github/workflows/build-installer.yml")
    assert "if: startsWith(github.ref, 'refs/tags/')" in workflow
    assert "needs: build-and-test" in workflow
    assert "--prerelease" in workflow
    assert "workflow_dispatch:" in workflow
