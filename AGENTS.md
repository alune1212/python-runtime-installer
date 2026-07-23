# Repository Guidelines

## Project Structure & Module Organization

`installer/` contains the Inno Setup project and generated installer constants. Build, audit, SBOM, and release tooling lives in `scripts/build/`; Windows PowerShell 5.1 runtime installation and removal logic lives in `scripts/windows/`. Product pins and policy files are under `config/`, operational guidance under `docs/`, and canonical requirements under `openspec/specs/`. Python tests are in `tests/test_*.py`; Pester contracts are in `tests/powershell/*.Tests.ps1`.

Do not commit generated output from `build/`, `payload/`, `wheelhouse/`, `installer/output/`, logs, certificates, or private keys.

## Build, Test, and Development Commands

Use the pinned UV version and locked environment:

```powershell
uv sync --frozen
uv lock --check
uv run ruff format --check .
uv run ruff check .
uv run pytest
uv run python -m scripts.build.validate_config
uv run python -m scripts.build.lock_requirements --check
uv run python -m scripts.build.validate_vulnerability_exceptions
uv run python -m scripts.build.scan_repository
openspec validate --all --strict
```

On Windows, also run PSScriptAnalyzer with `config/PSScriptAnalyzerSettings.psd1` and `Invoke-Pester -Path tests/powershell -CI -Output Detailed`. Build real installers only through the documented README sequence or `.github/workflows/build-installer.yml`; do not introduce an unverified shortcut.

## Coding Style & Naming Conventions

Target Python 3.13, use four-space indentation, 100-character lines, double quotes, and Ruff-managed imports. Name Python tests `test_<behavior>` and modules in `snake_case`. Keep PowerShell compatible with Windows PowerShell 5.1; use approved `Verb-Noun` functions, PascalCase parameters, and explicit error handling. Do not weaken hashes, version pins, analyzer rules, or transactional checks to make a gate pass.

## Testing Guidelines

Every behavior change needs a focused pytest or Pester regression test. Run the full local suite before opening a PR. Installer lifecycle changes also require the Windows workflow’s real EXE install, repair, uninstall, and evidence gates. There is no numeric coverage target; preserve meaningful contract coverage and failure-path assertions.

## Commit & Pull Request Guidelines

Use concise Simplified Chinese imperative subjects, optionally prefixed by scope, for example `fix: 修复 PowerShell 5.1 运行时检测`. Keep commits single-purpose. PRs must summarize behavior, risks, OpenSpec impact, and exact validation commands; link relevant issues and attach screenshots only for visible UI changes. Keep all CI checks green and never include secrets or generated artifacts.

## Security & Release Safety

Never modify global `PATH`, log credentials, or replace verified offline payloads. Tags, GitHub Releases, signing operations, and vulnerability exceptions require explicit review and must follow `docs/security-release.md`.
