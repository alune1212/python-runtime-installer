"""Read and validate the generated hash-locked runtime requirements."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

HASH_RE = re.compile(r"--hash=sha256:([0-9a-f]{64})(?:\s|$)")
PIN_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;]+)(.*)$")


def canonicalize_name(value: str) -> str:
    """Return the PEP 503 canonical form of *value*."""
    return re.sub(r"[-_.]+", "-", value).lower()


class LockError(ValueError):
    """Raised when requirements.txt is not an immutable hash lock."""


@dataclass(frozen=True)
class LockedRequirement:
    name: str
    version: str
    hashes: tuple[str, ...]

    @property
    def canonical_name(self) -> str:
        return canonicalize_name(self.name)


def _logical_lines(path: Path) -> list[str]:
    logical: list[str] = []
    current: list[str] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        continued = stripped.endswith("\\")
        current.append(stripped[:-1].rstrip() if continued else stripped)
        if not continued:
            logical.append(" ".join(current))
            current = []
    if current:
        raise LockError(f"unterminated continuation in {path}")
    return logical


def read_lock(path: Path) -> list[LockedRequirement]:
    requirements: list[LockedRequirement] = []
    seen: set[str] = set()
    for line in _logical_lines(path):
        if line.startswith("--"):
            raise LockError(f"index or global pip option is forbidden: {line}")
        match = PIN_RE.fullmatch(line)
        if not match:
            raise LockError(f"requirement is not an exact pin: {line}")
        name, version, remainder = match.groups()
        if any(token in remainder for token in (" @ ", ";", "--index", "--find-links")):
            raise LockError(f"URL, marker, or index option is forbidden: {line}")
        hashes = tuple(HASH_RE.findall(remainder))
        if not hashes:
            raise LockError(f"requirement has no SHA-256 hash: {name}=={version}")
        requirement = LockedRequirement(name=name, version=version, hashes=hashes)
        if requirement.canonical_name in seen:
            raise LockError(f"duplicate locked requirement: {requirement.canonical_name}")
        seen.add(requirement.canonical_name)
        requirements.append(requirement)
    if not requirements:
        raise LockError(f"no requirements found in {path}")
    return requirements


def locked_versions(path: Path) -> dict[str, str]:
    return {item.canonical_name: item.version for item in read_lock(path)}
