## Context

The repository currently contains only project initialization and OpenSpec metadata. The change introduces a complete Windows delivery pipeline while development is performed on macOS. Target users run Windows 10/11 x64, often without administrator rights and potentially with slow or unavailable access to PyPI or GitHub.

The product is an environment installer rather than an application launcher. It owns a virtual environment and may own a private CPython runtime, but it must coexist with system Python, Conda, Microsoft Store aliases, and user-installed tools. The agreed release baseline is version `0.1.0` with CPython `3.13.14` x64. Python and package content are immutable for a given installer version.

The design spans dependency resolution, Windows runtime installation, Inno Setup packaging, PowerShell orchestration, Python-level verification, local diagnostics, supply-chain evidence, code signing, and GitHub release automation.

## Goals / Non-Goals

**Goals:**

- Produce one self-contained offline Windows x64 setup executable from a Windows GitHub Actions runner.
- Install or repair a deterministic managed Python environment without administrator rights, target-time network access, or global `PATH` changes.
- Reuse an existing interpreter only when it exactly matches CPython 3.13.14 x64 and passes conservative health checks.
- Make activation transactional and ownership-aware, with functional verification, repair, upgrade, rollback, and safe uninstall behavior.
- Provide clear bilingual setup UX, silent deployment, stable discovery metadata, bounded local logs, and operator documentation.
- Gate releases on real-installer tests, artifact integrity, dependency auditing, license evidence, and SBOM generation.
- Support optional Authenticode signing and human-reviewed monthly dependency refreshes.

**Non-Goals:**

- Supporting ARM64, 32-bit Windows, Windows Server as a declared target, or Python versions other than the configured exact runtime.
- Modifying global `PATH`, installing for all users, requiring PowerShell 7, or requesting elevation.
- Accepting runtime requirements, installing arbitrary user packages, or preserving environment drift during repair or upgrade.
- Bundling Chrome, Edge, Firefox, or any WebDriver; running external database, MQTT, or browser integration tests during setup.
- Publishing automatically to a mainland-China cloud provider or configuring a permanent domestic PyPI mirror.
- Guaranteeing byte-for-byte identical signed EXEs across runner images; reproducibility applies to versioned source inputs, runtime, wheels, and installed environment content.

## Decisions

### 1. Use Inno Setup as the outer installer and PowerShell/Python for orchestration

Inno Setup will own the wizard, language selection, fixed per-user destination, architecture checks, file extraction, Start menu entries, uninstall registration, and invocation of runtime scripts. Target-side orchestration will use Windows PowerShell 5.1-compatible scripts. Python verification will run inside the staged environment because package import and functional tests are clearer and more reliable in Python.

The main components will be organized along these boundaries:

```text
config/                         version, runtime artifact, hashes, policy
installer/                      Inno Setup source and language messages
requirements.in                direct runtime requirements
requirements.txt               generated full hash lock
scripts/build/                  lock, wheelhouse, notices, SBOM, compile
scripts/windows/                detection, install, lifecycle, logging
scripts/verify_environment.py   package and functional smoke tests
tests/                          Python and PowerShell contract tests
.github/workflows/              CI, full build/release, monthly refresh
```

Alternative considered: a custom .NET bootstrapper. It would offer deeper native control but adds a second application stack and more code-signing/build complexity without improving the Python environment contract. Inno Setup plus narrow scripts is easier to maintain and audit.

### 2. Pin one product configuration as the source of build truth

A committed machine-readable configuration will hold installer version, CPython version, official x64 installer URL and SHA-256, architecture, fixed paths, product identity, and artifact naming. The version tag, Inno Setup metadata, manifest, wheel target, SBOM, and release filenames must derive from or be checked against this source.

CPython 3.13.14 is selected because the current Python 3.12 security releases no longer provide Windows binary installers. Reuse requires the exact patch version so the runtime is as controlled as the package graph.

Alternative considered: resolve `latest` during every build. This would make two runs from the same commit install different content and is incompatible with auditability.

### 3. Bundle the official full CPython installer and a Windows-only wheelhouse

The Windows build downloads the official CPython 3.13.14 x64 installer, checks its configured SHA-256, and packages it into the setup executable. Private installation uses current-user scope, a fixed application-owned runtime directory, no launcher, no file associations, no shortcuts, and no `PATH` prepend.

`requirements.in` lists only the required direct packages. A pinned build tool generates `requirements.txt` on Windows for CPython 3.13.14 with exact direct and transitive versions and hashes. The wheelhouse build requires binary wheels and fails if a source distribution would be needed. Target installation uses the equivalent of `--no-index`, `--find-links`, `--require-hashes`, and the committed lock.

Bootstrap packages such as pip, setuptools, and wheel are pinned separately as managed tooling when required. They are installed from the same offline payload and included in manifests and audits.

Alternative considered: an online bootstrapper with a domestic mirror. It creates regional trust, uptime, and version-drift dependencies. A fully offline installer is larger but moves all network and integrity work into CI.

### 4. Separate runtime selection, environment staging, and active discovery

Detection collects candidates from registered standard CPython installations and trusted launcher results, then executes explicit probes. Aliases, Conda, embedded layouts, inexact versions, wrong architectures, and failed health checks are rejected without mutation.

If no candidate passes, the bundled Python installer creates a private runtime under the application root. The private runtime is marked as installer-owned. If setup fails before activation, cleanup invokes the owned runtime's supported uninstall path and removes remaining owned staging content; it never attempts cleanup against a reused runtime.

The virtual environment is always created beneath a transaction-specific staging directory on the same volume as the final path. After offline installation and all smoke tests pass, activation performs this sequence:

1. Preserve the current active environment as a rollback candidate when present.
2. Rename the verified staged environment to the fixed active `venv` path.
3. Write the final manifest and `HKCU` discovery data.
4. Remove the previous environment after successful publication.
5. Restore the previous environment if promotion or discovery publication fails.

No staged path is published to the registry. All path handling uses explicit arguments and quoting and is tested with spaces and Chinese characters.

Alternative considered: in-place `pip install --upgrade`. It leaves partial state on failure and preserves undeclared packages, so it does not satisfy the immutable-environment contract.

### 5. Treat repair and upgrade as environment replacement

The installed manifest records installer version, base interpreter identity and ownership, dependency graph, payload hashes, build commit, and verification result. Lifecycle behavior is:

- First install: create and activate the locked environment.
- Same version: verify; keep a healthy environment or rebuild a drifted one.
- Newer version: transactionally replace the managed environment.
- Older version: fail without mutation; rollback requires uninstall followed by installing the older release.

User-added packages and files beneath the managed environment are outside the preservation contract. Documentation directs users to store code and data elsewhere.

### 6. Make functional verification part of the commit point

The verification program will confirm Python version, x64 architecture, executable location, virtual-environment isolation, package versions, manifest alignment, and `pip check`. It will then run small offline operations for the scientific, file, web, graph, data-generation, parsing, database-client, and MQTT-client packages.

Matplotlib uses the noninteractive `Agg` backend. Flask uses its test client. scikit-learn trains a tiny in-memory model. Selenium and webdriver-manager are imported only; no browser or driver is launched or downloaded. Temporary outputs are kept inside the transaction and cleaned after verification.

The verifier returns a stable nonzero exit code on any required failure so interactive and silent installs share the same gate.

### 7. Keep logs local, bounded, and useful after failure

PowerShell will use a small explicit logging layer rather than dumping the full process environment. It records timestamps, stages, safe command summaries, exit codes, package versions, and captured error output in English UTF-8. Inno Setup maintains its setup log alongside the orchestration log. The log directory is outside the application root so failure and uninstall do not erase evidence.

At startup, retention removes only logs older than the newest 20 recognized installer log sets. No telemetry or upload endpoint exists.

### 8. Expose the environment without changing global shell state

The installation directory is fixed at `%LOCALAPPDATA%\Programs\Python Runtime Installer`. Setup creates Start menu entries only:

- an environment terminal that launches the system command shell and activates `venv\Scripts\activate.bat`;
- the retained log directory;
- the Inno Setup uninstaller.

Machine-readable discovery is published beneath `HKCU\Software\Alune\Python Runtime Installer` with paths and versions mirrored in the JSON manifest. No user or system environment variable is created.

Inno Setup uses Simplified Chinese and English messages, while technical logs remain English. Silent mode uses the same underlying flow, returns zero only after activation and verification, and never restarts Windows.

### 9. Build and test the real executable on Windows

The CI design has three entry points:

- `ci.yml`: pull-request and ordinary-push static checks, tests, lock validation, and OpenSpec validation; no publication.
- `build-installer.yml`: manual dispatch and matching semantic-version tags; prepares payload, audits it, compiles Inno Setup, executes end-to-end installer tests, optionally signs, and uploads or releases artifacts.
- `dependency-update.yml`: monthly and manual lock refresh on Windows followed by the same gates and a pull request; no auto-merge or release.

The end-to-end test uses one test-only setup switch to force the bundled-runtime branch and a separate fault-injection switch that stops only after a complete staging verification and before promotion. Because GitHub-hosted Windows runners use Windows Server, a third explicit setup switch may bypass only the Windows Server edition rejection when both `GITHUB_ACTIONS=true` and `RUNNER_ENVIRONMENT=github-hosted`; Inno Setup and the PowerShell preflight independently enforce the same gate and fail closed when either marker is absent. It then verifies install, manifest, smoke-test result, idempotent same-version rerun, drift repair, failed-staging isolation, uninstall ownership, retained logs, and Unicode/space path contracts. Detection/reuse logic also receives focused tests using an isolated PEP 514 registration. None of these test switches can alter the OS major-version, x64, free-space, requirements, payload-integrity, dependency, transactional-activation, or functional-verification rules.

The GitHub-hosted Server exception is test infrastructure, not declared product support, and a normal Windows Server invocation remains rejected. GitHub's runner is not treated as evidence for desktop compatibility. Promotion to `1.0.0` requires a checked-in acceptance record from real Windows 10 x64 and Windows 11 x64 machines.

### 10. Make signing and release evidence explicit

Signing is conditional on repository secrets containing a base64-encoded PFX and its password. CI decodes it only on the ephemeral runner, signs with the Windows SDK signing tool, verifies Authenticode status, and deletes temporary certificate material. With no certificate, the build remains usable but carries `unsigned` in its filename and release notes warn about SmartScreen.

Release outputs include the EXE, `SHA256SUMS.txt`, CycloneDX JSON SBOM, third-party notices and required license/source material, and build provenance. Workflow actions and build tools are pinned. A secret scan runs before publication.

Dependency auditing fails on any known vulnerability unless a committed exception includes an identifier, reason, owner, and unexpired date. The exception validator fails closed on malformed or expired entries.

Alternative considered: allow security findings to produce warnings only. That makes a public release easy to create but defeats the agreed supply-chain gate.

### 11. Separate installation connectivity from artifact distribution

Installation has no network fallback and therefore needs no domestic package mirror. GitHub Releases remain the only automated publication target. Organizations may copy the complete artifact to an internal file server, enterprise drive, or domestic object store and verify it using the GitHub-published SHA-256.

This keeps the repository provider-neutral while acknowledging that downloading a large GitHub Release can be the remaining slow step for mainland users.

## Risks / Trade-offs

- [The offline EXE and staged upgrade require substantial disk space] → Check for 2 GB before mutation, use compression, clean extracted payloads, and document expected final size after the first real build.
- [An externally reused CPython may later be removed by its owner] → Verify it on every repair, keep ownership metadata, and rebuild against the private runtime when the base no longer qualifies.
- [Antivirus or a running Python process may block atomic rename or cleanup] → Preserve the old active environment until promotion succeeds, fail without changing discovery metadata, and provide actionable log messages.
- [Unsigned builds may trigger SmartScreen] → Mark unsigned filenames and documentation clearly and keep production signing ready in CI.
- [Python/package releases or wheel availability may invalidate a refresh] → Require binary wheels, run the full installer gate on update PRs, and never auto-merge.
- [GitHub Actions Windows images and network services drift] → Pin actions and tools where possible, verify every downloaded artifact, and keep build stages retryable without weakening hashes.
- [GitHub-hosted runners do not represent Windows 10/11 desktops] → Keep the `0.x` prerelease designation until manual acceptance succeeds on both target operating systems.
- [Third-party licenses may impose redistribution duties] → Generate notices and license/source evidence from the exact wheel set and block release when required metadata is missing.
- [Monthly PR creation depends on repository workflow permissions] → Document the required `contents` and `pull-requests` permissions and make a failed scheduled workflow visible rather than bypassing review.

## Migration Plan

1. Add the pinned product configuration, dependency input, lock generation, and validation tooling.
2. Implement detection, logging, staging, verification, lifecycle, discovery, and uninstall scripts with focused tests.
3. Add Inno Setup packaging and local Windows build scripts.
4. Add CI, supply-chain evidence, signing hooks, monthly update workflow, and end-to-end installer tests.
5. Complete user, maintainer, troubleshooting, signing, and acceptance documentation.
6. Manually dispatch a full Windows build and resolve all release gates.
7. Tag `v0.1.0` to publish a prerelease.
8. Validate on real Windows 10 and Windows 11 x64 systems before promoting a later validated build to `v1.0.0`.

Rollback from a released version is performed by uninstalling the current product and installing a previously retained release; direct downgrade is intentionally blocked.

## Open Questions

None. Exact package versions, hashes, pinned action revisions, and the current Inno Setup tool version are implementation-time facts that must be resolved and committed by the lock/build tasks without changing the approved behavior.
