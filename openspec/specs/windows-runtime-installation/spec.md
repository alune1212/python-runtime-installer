# windows-runtime-installation Specification

## Purpose
TBD - created by archiving change build-offline-python-runtime-installer. Update Purpose after archive.
## Requirements
### Requirement: Supported Windows platform
The installer SHALL support Windows 10 and Windows 11 on x64 processors only and SHALL require at least 2 GB of free space before making managed-system changes.

#### Scenario: Supported host passes preflight
- **WHEN** the installer runs on Windows 10 or Windows 11 x64 with at least 2 GB free
- **THEN** platform preflight succeeds and installation may continue

#### Scenario: Unsupported architecture is rejected
- **WHEN** the installer runs on ARM64 or a 32-bit Windows installation
- **THEN** it exits with an unsupported-platform message before creating or changing the managed runtime

#### Scenario: Insufficient disk space is rejected
- **WHEN** less than 2 GB of free space is available
- **THEN** it reports the required and available space and exits before creating or changing the managed runtime

### Requirement: Exact runtime detection and reuse
The installer SHALL reuse only a healthy standard CPython 3.13.14 x64 interpreter and SHALL leave every rejected candidate unchanged.

#### Scenario: Exact healthy CPython is reused
- **WHEN** discovery finds CPython 3.13.14 x64 and execution, `venv`, `ensurepip`, SSL, standard-library, and temporary-venv health checks pass
- **THEN** the installer records the interpreter as reused and uses it as the virtual environment base

#### Scenario: Inexact runtime is preserved
- **WHEN** discovery finds a Python version other than CPython 3.13.14 x64
- **THEN** the installer does not modify or remove it and selects the bundled private runtime

#### Scenario: Nonstandard or unhealthy runtime is rejected
- **WHEN** a candidate is a Microsoft Store execution alias, Conda runtime, embedded distribution, inaccessible executable, or fails a health check
- **THEN** the installer leaves the candidate unchanged and selects the bundled private runtime

### Requirement: Private per-user runtime
When no reusable runtime exists, the installer SHALL install its bundled CPython runtime for the current user at `%LOCALAPPDATA%\Programs\Python Runtime Installer` without requiring elevation, changing global `PATH`, or permanently changing PowerShell execution policy.

#### Scenario: Private runtime installation
- **WHEN** no reusable interpreter passes detection
- **THEN** the bundled runtime is installed beneath the fixed application directory with no administrator prompt and no global `PATH` modification

#### Scenario: Runtime scripts use built-in PowerShell
- **WHEN** installation logic is invoked on a target computer
- **THEN** it runs under Windows PowerShell 5.1 with a process-scoped execution-policy bypass and does not require PowerShell 7

### Requirement: Transactional environment activation
The installer SHALL build the managed environment in a staging location and SHALL expose it as the active environment only after integrity checks and functional verification succeed.

#### Scenario: Successful staged installation
- **WHEN** runtime setup, dependency installation, and all verification steps succeed in staging
- **THEN** the staged environment is atomically promoted to the fixed active location and discovery metadata is published

#### Scenario: Failed staged installation
- **WHEN** any runtime, dependency, or verification step fails
- **THEN** the incomplete staging environment is removed, no failed environment is advertised as active, pre-existing Python installations remain unchanged, and diagnostic logs are retained

#### Scenario: Unicode path handling
- **WHEN** the current user profile or a test path contains spaces or non-ASCII characters
- **THEN** staging, verification, activation, and cleanup complete without path truncation or encoding errors

### Requirement: Managed environment lifecycle
The installer SHALL support first installation, same-version repair, forward upgrade, and explicit downgrade rejection using installer, Python, dependency, and ownership metadata.

#### Scenario: Same-version repair
- **WHEN** the installed version equals the executing installer version
- **THEN** the installer verifies the environment and transactionally rebuilds it when drift or corruption is detected

#### Scenario: Forward upgrade
- **WHEN** the executing installer version is newer than the installed version
- **THEN** it transactionally replaces the managed environment with the new locked environment

#### Scenario: Downgrade is blocked
- **WHEN** the executing installer version is older than the installed version
- **THEN** it exits with instructions to uninstall first and makes no managed-environment changes

#### Scenario: User-added packages are not preserved
- **WHEN** repair or upgrade rebuilds an environment containing packages outside the locked manifest
- **THEN** the active environment contains only the newly locked environment and does not promise to retain those additions

### Requirement: Ownership-aware uninstall
Uninstall SHALL remove only installer-owned runtime files, the managed virtual environment, application files, shortcuts, and discovery metadata, while preserving reused Python installations and retained logs.

#### Scenario: Uninstall after private runtime installation
- **WHEN** the application owns the bundled private runtime
- **THEN** uninstall removes that runtime and the managed environment

#### Scenario: Uninstall after runtime reuse
- **WHEN** the managed environment was based on a pre-existing reusable CPython installation
- **THEN** uninstall removes the managed environment but does not modify or remove the reused interpreter

