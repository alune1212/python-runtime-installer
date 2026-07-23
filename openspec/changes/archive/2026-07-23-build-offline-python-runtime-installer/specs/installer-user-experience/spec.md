## ADDED Requirements

### Requirement: Bilingual interactive installation
The setup wizard SHALL provide Simplified Chinese and English user-facing text, default to the Windows display language when supported, and present clear summaries for unsupported systems, failures, success, repair, upgrade, and downgrade rejection.

#### Scenario: Chinese Windows installation
- **WHEN** the installer runs on a Simplified Chinese Windows profile
- **THEN** the wizard and user-facing result summaries are displayed in Simplified Chinese

#### Scenario: English fallback
- **WHEN** the Windows display language is not Simplified Chinese
- **THEN** the installer displays English user-facing text

### Requirement: Silent enterprise deployment
The same executable SHALL support unattended installation with no restart, deterministic exit codes, full verification, and complete local logging.

#### Scenario: Successful silent installation
- **WHEN** setup runs with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`
- **THEN** it shows no interactive prompts, performs the same validation as interactive setup, and returns exit code zero

#### Scenario: Failed silent installation
- **WHEN** an unattended install fails preflight, setup, or verification
- **THEN** it returns a nonzero exit code, does not restart Windows, and records the failure in the local log

### Requirement: Fixed non-global user entry points
The product SHALL use the fixed per-user installation path, SHALL NOT offer a custom path or modify global `PATH`, SHALL create Start menu entries only, and SHALL NOT create a desktop shortcut.

#### Scenario: Start menu entries are created
- **WHEN** installation succeeds
- **THEN** the Start menu contains entries to open an automatically activated environment terminal, open installation logs, and uninstall the product

#### Scenario: Dedicated interpreter path is usable
- **WHEN** a user or another program invokes `<InstallPath>\venv\Scripts\python.exe`
- **THEN** it runs inside the managed environment without relying on global `PATH`

### Requirement: Local privacy-preserving logs
The installer SHALL write UTF-8 English technical logs to `%LOCALAPPDATA%\PythonRuntimeInstaller\Logs`, retain the newest 20 logs, and SHALL NOT upload telemetry or record complete environment-variable sets or user-file contents.

#### Scenario: Installation log is generated
- **WHEN** an install, repair, upgrade, verification, or failure occurs
- **THEN** a timestamped log records installer and Windows versions, command results, Python and package versions, and relevant error stacks

#### Scenario: Log retention is bounded
- **WHEN** a new log would make the directory contain more than 20 retained logs
- **THEN** the oldest excess logs are removed and the newest 20 remain

#### Scenario: Logs survive uninstall
- **WHEN** the product is uninstalled
- **THEN** retained logs remain available and documentation explains how to delete them manually

### Requirement: Stable environment discovery
Successful installation SHALL publish current-user discovery metadata at `HKCU\Software\Alune\Python Runtime Installer` and in the installed JSON manifest without creating a global environment variable.

#### Scenario: Discovery metadata is available
- **WHEN** installation or upgrade succeeds
- **THEN** the registry contains `InstallPath`, `PythonExecutable`, `PythonVersion`, `InstallerVersion`, and `ManifestPath` values matching the active environment

#### Scenario: Failed staging is not discoverable
- **WHEN** installation fails before activation
- **THEN** no registry metadata points to the failed staged environment

### Requirement: Troubleshooting and operational documentation
The repository SHALL document interactive and silent installation, environment invocation, log locations, error handling, uninstall, code-signing warnings, Selenium runtime limitations, and offline distribution guidance for mainland China.

#### Scenario: Mainland user guidance
- **WHEN** a user needs to obtain or install the package in mainland China
- **THEN** documentation distinguishes downloading the large EXE from running it offline and recommends verified internal or domestic artifact distribution using the published SHA-256

