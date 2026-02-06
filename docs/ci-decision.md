# CI Decision

Date: 2026-02-06
Decision: FULL CI

## Why FULL CI
- The repo contains executable update logic (`update_cs2.sh`) and deterministic unit-style tests under `tests/`.
- No production secrets or live infrastructure access are required for lint/tests/security checks.
- Runtime is short (single job, expected < 2 minutes), so it is suitable for every PR and push to `main`.
- The checks reduce regression risk for service restart logic and update detection.

## What Runs Where
- Pull Requests (including forks): Lint, Tests, Secret Scan (no secrets).
- Push to `main`: Same as PR checks.
- Manual (`workflow_dispatch`): Same as PR checks (useful for debugging).

## CI Threat Model
- Untrusted PRs: Only `pull_request` event is used (no `pull_request_target`).
- No secrets are read in PR jobs; workflow only needs `contents: read`.
- External downloads: `shellcheck` and `shfmt` are fetched from GitHub Releases with pinned versions and SHA256 verification.
- No write permissions, deployments, or artifact publishing.

## Limits and Assumptions
- Integration tests that require real SteamCMD, systemd, or live servers are not run on GitHub-hosted runners.
- Tool versions are pinned in `scripts/ci-tools-versions.env`. Updating them requires a conscious change.

## If We Later Need Deeper CI
- Add a self-hosted runner with SteamCMD + systemd for real update/rollback testing.
- Split long-running integration tests into scheduled or manual workflows.
- Add SCA tooling if dependency manifests are introduced.
