from __future__ import annotations

from pathlib import Path

import pytest

from scripts.build.requirements_lock import LockError, locked_versions, read_lock
from scripts.build.validate_config import EXPECTED_DIRECT_REQUIREMENTS

HASH_A = "a" * 64
HASH_B = "b" * 64


def write_lock(path: Path, content: str) -> Path:
    path.write_text(content, encoding="utf-8")
    return path


def test_reads_exact_multiline_hash_lock(tmp_path: Path) -> None:
    lock = write_lock(
        tmp_path / "requirements.txt",
        f"Demo_Package==1.2.3 \\\n+    --hash=sha256:{HASH_A} \\\n+    --hash=sha256:{HASH_B}\n",
    )
    items = read_lock(lock)
    assert items[0].canonical_name == "demo-package"
    assert items[0].hashes == (HASH_A, HASH_B)
    assert locked_versions(lock) == {"demo-package": "1.2.3"}


@pytest.mark.parametrize(
    "line",
    [
        "demo>=1.0\n",
        "demo==1.0\n",
        f"--index-url https://example.invalid\ndemo==1.0 --hash=sha256:{HASH_A}\n",
        f"demo==1.0; python_version>'3' --hash=sha256:{HASH_A}\n",
    ],
)
def test_rejects_mutable_or_network_lock_content(tmp_path: Path, line: str) -> None:
    with pytest.raises(LockError):
        read_lock(write_lock(tmp_path / "requirements.txt", line))


def test_committed_runtime_and_bootstrap_locks_are_valid() -> None:
    runtime = read_lock(Path("requirements.txt"))
    bootstrap = read_lock(Path("bootstrap-requirements.txt"))
    assert {item.canonical_name for item in runtime} >= EXPECTED_DIRECT_REQUIREMENTS
    assert [item.canonical_name for item in bootstrap] == ["pip"]
