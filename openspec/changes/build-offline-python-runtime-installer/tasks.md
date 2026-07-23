## 1. Project Foundation and Pinned Configuration

- [x] 1.1 Create the `config`, `installer`, `scripts/build`, `scripts/windows`, `tests`, and documentation directory structure with generated payload and secret-bearing paths ignored by Git.
- [x] 1.2 Add the machine-readable product configuration for version `0.1.0`, product identity, fixed paths, Windows x64, CPython `3.13.14`, official artifact URL, and verified SHA-256.
- [x] 1.3 Add configuration validation that fails on unsupported architectures, malformed hashes, inconsistent versions, or a release tag that does not match the product version.
- [x] 1.4 Add pinned build and test tool requirements for locking, auditing, SBOM generation, license reporting, Python tests, and PowerShell analysis.
- [x] 1.5 Add a documented vulnerability-exception schema with required identifier, reason, owner, and expiry fields, initially containing no active exceptions.

## 2. Dependency Lock and Offline Payload

- [x] 2.1 Add `requirements.in` containing exactly the 14 approved direct runtime packages and comments documenting the immutable dependency policy.
- [x] 2.2 Implement the Windows lock script to select compatible stable non-prerelease versions for CPython 3.13.14 x64 and generate a fully pinned, hash-checked `requirements.txt`.
- [x] 2.3 Generate and commit the initial `requirements.txt`, then verify that every direct and transitive package resolves without a source distribution.
- [x] 2.4 Implement wheelhouse creation using the committed lock, binary-only downloads, and no dependency resolution drift.
- [x] 2.5 Generate and verify a payload manifest containing SHA-256 values for the CPython installer, every wheel, bootstrap tooling, and installed metadata inputs.
- [x] 2.6 Generate third-party notices and required license/source evidence from the exact wheel set, failing when mandatory license material is missing.
- [x] 2.7 Generate a CycloneDX JSON SBOM for Python, bootstrap tooling, direct dependencies, and transitive dependencies.
- [x] 2.8 Implement dependency vulnerability auditing and expiry validation so unexcepted or expired findings block the build.

## 3. Windows Preflight, Logging, and Runtime Selection

- [x] 3.1 Implement a Windows PowerShell 5.1-compatible UTF-8 logger with stage names, safe command summaries, exit codes, error capture, and newest-20 log retention.
- [x] 3.2 Implement preflight checks for Windows 10/11 x64 and 2 GB free space before any managed-system change.
- [x] 3.3 Implement conservative discovery of registered standard CPython and trusted launcher candidates without treating Microsoft Store aliases as installations.
- [x] 3.4 Implement exact CPython 3.13.14 x64 health probes for execution, implementation identity, `venv`, `ensurepip`, SSL, standard library, and temporary virtual-environment operation.
- [x] 3.5 Implement the bundled current-user CPython installation with fixed target path, no launcher, file associations, shortcuts, elevation, or `PATH` changes.
- [x] 3.6 Add runtime ownership metadata and supported cleanup so failed setup or uninstall removes only a privately installed runtime and never a reused interpreter.
- [x] 3.7 Add focused tests for exact reuse, inexact versions, wrong architecture, aliases, Conda/embedded candidates, failed health probes, and Unicode/space paths.

## 4. Transactional Environment Lifecycle

- [x] 4.1 Implement transaction-specific staging beneath the fixed application root and guarantee same-volume promotion semantics.
- [x] 4.2 Install bootstrap tooling and runtime dependencies into staging exclusively from the bundled wheelhouse with index access disabled and hashes required.
- [x] 4.3 Implement target-time payload hash verification that stops before execution or installation on any mismatch.
- [x] 4.4 Write the installed JSON manifest with installer version, build commit, Python identity and ownership, executable path, package versions, payload hashes, and verification result.
- [x] 4.5 Implement atomic activation, previous-environment preservation, registry publication, post-promotion cleanup, and rollback on promotion failure.
- [x] 4.6 Implement first-install and same-version behavior that retains a healthy matching environment and transactionally rebuilds a corrupt or drifted environment.
- [x] 4.7 Implement forward upgrade and fail-closed downgrade rejection with clear exit codes and no mutation on downgrade.
- [x] 4.8 Implement ownership-aware uninstall for the managed virtual environment, private runtime, application files, shortcuts, and registry data while retaining logs.
- [x] 4.9 Add lifecycle tests for failed staging, successful promotion, rollback, repair, drift removal, upgrade, downgrade rejection, reused runtime preservation, and log retention.

## 5. Post-install Verification

- [x] 5.1 Implement verifier checks for Python version, x64 architecture, virtual-environment isolation, interpreter location, manifest alignment, exact package versions, and `pip check`.
- [x] 5.2 Implement import checks using the correct module names for every declared package and return stable nonzero failure codes.
- [x] 5.3 Implement offline NumPy/Pandas calculations, OpenPyXL workbook round trip, Matplotlib `Agg` rendering, and small scikit-learn training smoke tests.
- [x] 5.4 Implement offline Flask test-client, NetworkX, Faker, BeautifulSoup, MySQL connector, and Paho MQTT client-construction smoke tests without external connections.
- [x] 5.5 Implement Selenium and webdriver-manager import/metadata checks that never launch a browser or download a WebDriver.
- [x] 5.6 Add deterministic tests for verifier success and for failures caused by version drift, missing imports, dependency conflicts, and functional-test errors.

## 6. Inno Setup Installer and User Experience

- [x] 6.1 Add the Inno Setup project with stable `AppId`, product metadata, per-user privileges, fixed `%LOCALAPPDATA%` path, x64-only guards, compression, and no restart behavior.
- [x] 6.2 Package the verified CPython installer, wheelhouse, manifests, runtime scripts, verifier, licenses, and required metadata into one offline executable.
- [x] 6.3 Wire Inno Setup to preflight and lifecycle scripts with correctly quoted parameters, process-scoped PowerShell bypass, propagated exit codes, setup logging, and transactional failure handling.
- [x] 6.4 Add Simplified Chinese and English wizard text with localized success and actionable failure summaries while keeping technical logs in English.
- [x] 6.5 Support interactive and `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` modes through the same installation and verification path.
- [x] 6.6 Create Start menu entries for an automatically activated environment terminal, retained logs, and uninstall; verify that no desktop shortcut or global environment variable is created.
- [x] 6.7 Write and remove the `HKCU\Software\Alune\Python Runtime Installer` discovery values only when activation or uninstall succeeds.
- [x] 6.8 Add a test-only force-bundled switch that changes runtime selection without changing requirements, wheelhouse content, paths, or security checks.

## 7. Automated Tests and Windows Build Pipeline

- [x] 7.1 Add cross-platform Python unit tests and Windows PowerShell contract tests, including simulated paths containing spaces and Chinese characters.
- [x] 7.2 Add formatting, Python lint/test, PowerShell analysis/test, lock consistency, secret scanning, and strict OpenSpec validation commands for contributors.
- [x] 7.3 Add a pull-request and ordinary-push CI workflow with least-privilege permissions and every third-party action pinned to a full commit SHA.
- [x] 7.4 Add the Windows full-build workflow to install pinned build tools, verify CPython and Inno Setup downloads, generate the payload, and compile the versioned executable.
- [x] 7.5 Run the built EXE silently with the forced private runtime and assert successful verification, fixed paths, registry metadata, manifest content, Start menu entries, and retained logs.
- [x] 7.6 Rerun the same EXE to test idempotent repair, then silently uninstall and assert owned-content removal plus reused-runtime and log preservation.
- [x] 7.7 Add controlled tests for the reusable-interpreter branch and make every end-to-end failure block artifact upload or release.

## 8. Signing, Release Evidence, and Publication

- [x] 8.1 Add optional PFX-based Authenticode signing using repository secrets, ephemeral certificate handling, timestamp support, and signature verification.
- [x] 8.2 Name unsigned artifacts with an `unsigned` suffix and include the SmartScreen warning when signing secrets are absent.
- [x] 8.3 Generate final `SHA256SUMS.txt`, CycloneDX SBOM, third-party notices, license/source material, and build provenance beside the executable.
- [x] 8.4 Scan release outputs for secret material and verify that checksums, SBOM components, notices, manifest versions, Git commit, and workflow run agree before publication.
- [x] 8.5 Upload complete outputs as Actions artifacts for manual workflow runs without creating a Release.
- [x] 8.6 Create a GitHub Release only for a matching `vX.Y.Z` tag after all gates pass, publishing only the signed EXE when signing is configured.
- [x] 8.7 Mark `0.x` GitHub Releases, including `0.1.0`, as prereleases and prevent ordinary pushes or pull requests from publishing.

## 9. Human-reviewed Dependency Refresh

- [x] 9.1 Implement the monthly and manual Windows refresh workflow to check the CPython artifact and stable package updates, regenerate locks and evidence, and run all security and functional gates.
- [x] 9.2 Configure least-privilege pull-request creation for successful refresh changes and document the required repository Actions permission.
- [x] 9.3 Ensure the refresh workflow never auto-merges, tags, or publishes and exposes incompatible wheels, audit findings, or functional failures for maintainer review.
- [x] 9.4 Add tests for malformed or expired vulnerability exceptions and for refresh output that is unchanged.

## 10. Documentation and Release Acceptance

- [x] 10.1 Write the Chinese-first README with architecture, complete project structure, macOS development workflow, Windows build commands, installation, silent deployment, environment use, repair, upgrade, downgrade, and uninstall instructions.
- [x] 10.2 Document log locations and redaction policy, fixed paths, registry discovery, custom-package reset behavior, Selenium/WebDriver limitations, and troubleshooting procedures.
- [x] 10.3 Document optional code-signing secrets, unsigned-build behavior, release gates, SBOM/checksum verification, vulnerability exceptions, and third-party redistribution obligations.
- [x] 10.4 Document that target installation is fully offline, explain why no package mirror is configured, and provide checksum-based guidance for internal or domestic redistribution of the GitHub artifact.
- [x] 10.5 Add a real-device acceptance checklist for Windows 10 x64 and Windows 11 x64 covering interactive install, silent install, no-admin behavior, Chinese paths, repair, upgrade, uninstall, and SmartScreen/signature state.
- [x] 10.6 Validate the complete repository with local checks, a manually dispatched Windows full build, strict OpenSpec validation, and clean diff checks before tagging `v0.1.0`.
