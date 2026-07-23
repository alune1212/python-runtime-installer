## Why

Windows 10/11 users need a repeatable one-click Python environment without depending on slow or unavailable package indexes during installation. The project must be buildable from macOS through a Windows CI runner while producing an auditable, supportable, and safely updatable installer for public or enterprise distribution.

## What Changes

- Add a single offline Windows x64 installer that bundles an exact CPython 3.13.14 runtime and a hash-locked wheelhouse for the required data, database, web, automation, plotting, and machine-learning packages.
- Detect and reuse only a healthy, standard CPython 3.13.14 x64 installation; otherwise install a private per-user runtime without administrator rights or global `PATH` changes.
- Create a managed virtual environment transactionally, verify it with dependency checks and functional smoke tests, and retain diagnostic logs when installation fails.
- Provide bilingual interactive setup, silent deployment, Start menu entry points, stable registry discovery metadata, repair and upgrade behavior, and safe uninstall behavior.
- Add GitHub Actions workflows that lock and audit dependencies, build the Inno Setup executable on Windows, test the real installer end to end, optionally sign it, and publish release evidence including checksums, licenses, and an SBOM.
- Add a monthly dependency-update pull request workflow with human review and vulnerability-gated releases.
- Document build, release, installation, troubleshooting, mainland-China distribution, signing, and real Windows 10/11 acceptance procedures.

## Capabilities

### New Capabilities

- `windows-runtime-installation`: Offline per-user CPython detection, private runtime installation, transactional virtual-environment creation, repair, upgrade, rollback, and uninstall behavior on Windows 10/11 x64.
- `locked-python-environment`: Immutable requirements locking, offline wheelhouse installation, package integrity checks, manifest generation, and post-install functional verification.
- `installer-user-experience`: Bilingual and silent setup behavior, fixed paths, local privacy-preserving logs, Start menu entry points, and registry-based environment discovery.
- `windows-build-and-release`: Windows CI build, end-to-end installer testing, optional Authenticode signing, release publication, dependency update automation, vulnerability gates, checksums, license notices, and SBOM generation.

### Modified Capabilities

None. This repository has no existing baseline capability specs.

## Impact

- Adds Inno Setup definitions, Windows PowerShell 5.1 runtime scripts, Python validation code, dependency inputs and lock files, build metadata, and supporting test fixtures.
- Adds GitHub Actions workflows that require Windows runners, release and pull-request permissions, and optional code-signing secrets.
- Produces a large offline executable plus checksum, CycloneDX SBOM, and third-party notice artifacts.
- Establishes `%LOCALAPPDATA%\Programs\Python Runtime Installer` as the fixed managed runtime path and `HKCU\Software\Alune\Python Runtime Installer` as its discovery contract.
- Does not modify global `PATH`, install browser binaries or WebDrivers, read user-supplied requirements, upload telemetry, or depend on a mainland package mirror at install time.
