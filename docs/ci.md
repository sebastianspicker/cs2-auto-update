# CI Overview

Workflow: `CI` (`.github/workflows/ci.yml`)

## Triggers
- `pull_request` (all PRs)
- `push` to `main`
- `workflow_dispatch` (manual)

## Jobs
- `Lint • Test • Security`
  - Lint: `scripts/lint.sh` (bash -n, shellcheck, shfmt -d)
  - Tests: `tests/run.sh`
  - Security: `scripts/security.sh` (secret regex + dependency manifest guard)

## Tooling and Caching
- CI installs pinned versions of `shellcheck` and `shfmt` via `scripts/ci-install-tools.sh`.
- Versions and shellcheck SHA256 checksums are defined in `scripts/ci-tools-versions.env`.
- `shfmt` checksums are verified against `sha256sums.txt` from the official release.
- Downloads are cached in `.cache/ci-tools` using `actions/cache`.

## Local Runs
Use the Makefile targets:
- `make ci`
- `make lint`
- `make test`
- `make security`

Install tools locally (same as `scripts/lint.sh`):
- Ubuntu/Debian: `sudo apt-get update && sudo apt-get install -y shellcheck shfmt`
- macOS (Homebrew): `brew install shellcheck shfmt`

## Secrets and Repo Settings
- No secrets are required for CI.
- Workflow permissions: `contents: read` only.

## Extending CI
- Add steps to `.github/workflows/ci.yml` or split into additional jobs if needed.
- Update `scripts/ci-tools-versions.env` when upgrading tool versions.
- If dependency manifests are introduced, add SCA tooling and update `scripts/security.sh` and this doc.
