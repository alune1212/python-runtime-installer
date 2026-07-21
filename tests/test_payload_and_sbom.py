from __future__ import annotations

from pathlib import Path

from scripts.build.generate_payload_manifest import build_manifest, verify_manifest
from scripts.build.generate_sbom import make_sbom


def test_payload_manifest_detects_tampering_and_path_escape(tmp_path: Path) -> None:
    payload = tmp_path / "payload"
    payload.mkdir()
    wheel = payload / "wheelhouse" / "demo.whl"
    wheel.parent.mkdir()
    wheel.write_bytes(b"verified")
    manifest = build_manifest(payload, payload / "payload-manifest.json")
    assert verify_manifest(payload, manifest) == []

    extra = payload / "unexpected.txt"
    extra.write_text("not manifested", encoding="utf-8")
    assert "unexpected unmanifested payload file: unexpected.txt" in verify_manifest(
        payload, manifest
    )
    extra.unlink()

    wheel.write_bytes(b"tampered")
    errors = verify_manifest(payload, manifest)
    assert any("size mismatch" in error or "hash mismatch" in error for error in errors)

    manifest["files"] = [{"path": "../outside", "size": 0, "sha256": "0" * 64}]
    assert "manifest path escapes payload root: ../outside" in verify_manifest(payload, manifest)


def test_sbom_contains_python_runtime_bootstrap_and_all_locked_packages() -> None:
    sbom = make_sbom(Path("requirements.txt"), Path("bootstrap-requirements.txt"))
    components = sbom["components"]
    assert isinstance(components, list)
    names = [component["name"] for component in components]
    assert names[0] == "CPython"
    assert "pandas" in names
    assert "Inno Setup" in names
    assert "Inno Setup Chinese Simplified Translation" in names
    assert "mysql-connector-python" in names
    assert names.count("pip") == 1
    assert sbom["bomFormat"] == "CycloneDX"
    assert sbom["specVersion"] == "1.6"
