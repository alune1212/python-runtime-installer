# windows-build-and-release Specification

## Purpose
TBD - created by archiving change build-offline-python-runtime-installer. Update Purpose after archive.
## Requirements
### Requirement: Windows-native reproducible build
The repository SHALL allow development on macOS while building the final Inno Setup executable on a GitHub-hosted Windows runner from pinned project configuration, dependency locks, build-tool versions, and verified upstream artifacts.

#### Scenario: Windows build produces one installer
- **WHEN** the full build workflow runs successfully
- **THEN** it downloads and verifies the configured CPython 3.13.14 x64 installer, prepares the locked wheelhouse, and emits one versioned Windows x64 setup executable

#### Scenario: Version mismatch blocks build
- **WHEN** the release tag, installer version configuration, dependency target, or Python artifact metadata disagree
- **THEN** the workflow fails before publication

### Requirement: CI trigger and publication policy
Pull requests and ordinary pushes SHALL validate without publishing releases, manual dispatch SHALL produce an Actions artifact, and a matching `vX.Y.Z` tag SHALL create a GitHub Release.

#### Scenario: Pull request validation
- **WHEN** a pull request changes installer, scripts, requirements, or workflows
- **THEN** CI runs the applicable static, lock, security, and test checks without publishing a release

#### Scenario: Manual full build
- **WHEN** an authorized user dispatches the build workflow
- **THEN** CI performs the complete build and uploads its outputs as Actions artifacts without creating a GitHub Release

#### Scenario: Tagged release
- **WHEN** a matching semantic-version tag is pushed and every release gate succeeds
- **THEN** CI creates a GitHub Release containing the approved artifacts

#### Scenario: Initial release is prerelease
- **WHEN** the version is `0.1.0` or another `0.x` version
- **THEN** the GitHub Release is marked as a prerelease

### Requirement: Real installer release gate
The Windows workflow SHALL execute the produced setup executable and verify forced bundled-runtime installation, functional validation, same-version repair, ownership-aware uninstall, retained logs, and Unicode/space path handling before publication.

#### Scenario: End-to-end installer test passes
- **WHEN** the built executable completes install, verification, repair, and uninstall checks on the Windows runner
- **THEN** the workflow may proceed to signing and publication

#### Scenario: End-to-end installer test fails
- **WHEN** any actual setup or uninstall assertion fails
- **THEN** the workflow blocks artifact release and retains CI diagnostics

### Requirement: Optional Authenticode signing
The release workflow SHALL sign and verify the installer when signing credentials are configured and SHALL still support clearly named unsigned development or prerelease artifacts when credentials are absent.

#### Scenario: Signing credentials are available
- **WHEN** the configured certificate and secret are present
- **THEN** the workflow Authenticode-signs the executable, verifies the resulting signature, and publishes only the signed executable

#### Scenario: Signing credentials are absent
- **WHEN** no signing certificate is configured
- **THEN** the workflow publishes a runnable artifact whose filename clearly includes `unsigned` and documentation warns about SmartScreen

### Requirement: Release evidence and public-distribution compliance
Every published release SHALL include the installer, SHA-256 checksums, a CycloneDX JSON SBOM, third-party notices and applicable license material, and build provenance without embedded repository tokens, mirror credentials, or signing secrets.

#### Scenario: Release evidence is complete
- **WHEN** a release is ready to publish
- **THEN** the evidence identifies Python, all direct and transitive packages, versions, sources, licenses, artifact hashes, build commit, and workflow run

#### Scenario: Secret scanning fails closed
- **WHEN** generated artifacts contain configured secret values or forbidden credential material
- **THEN** publication is blocked

### Requirement: Vulnerability-gated dependencies
The release workflow SHALL audit the complete locked dependency graph and SHALL block known vulnerabilities unless a repository exception identifies the vulnerability, documents the risk and owner, and has not passed its explicit expiry date.

#### Scenario: Vulnerability without exception
- **WHEN** the audit finds a known vulnerability with no valid exception
- **THEN** the release workflow fails

#### Scenario: Expired exception
- **WHEN** an exception's expiry date is in the past
- **THEN** the workflow treats the vulnerability as unexcepted and fails

### Requirement: Human-reviewed dependency refresh
A scheduled monthly Windows workflow SHALL check Python and package updates, regenerate locked artifacts, run the full validation path, and create a pull request for changes without automatically merging or publishing them.

#### Scenario: Compatible updates are available
- **WHEN** the monthly workflow finds compatible stable updates that pass all gates
- **THEN** it creates or updates a reviewable dependency-refresh pull request

#### Scenario: Update fails validation
- **WHEN** refreshed dependencies fail wheel, audit, build, or functional verification
- **THEN** no update is merged or released automatically and CI exposes the failure for maintainers

### Requirement: Distribution boundary and desktop acceptance
Automated publication SHALL target GitHub Releases only, and promotion to version 1.0.0 SHALL require documented acceptance on at least one real Windows 10 x64 computer and one real Windows 11 x64 computer.

#### Scenario: Domestic redistribution
- **WHEN** an organization mirrors the release to an internal server or domestic object store
- **THEN** recipients can verify the mirrored executable against the GitHub-published SHA-256 without changing installer behavior

#### Scenario: Stable promotion gate
- **WHEN** maintainers propose the first 1.0.0 release
- **THEN** the release checklist requires recorded successful Windows 10 and Windows 11 acceptance results

