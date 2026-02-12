# Issue Audit

Historical audit of CI, findings, and decisions. Kept for traceability.

---

## CI Audit (2026-02-06)

### Workflow inventory (current)
- Workflow: `CI` (`.github/workflows/ci.yml`)
- Triggers: `push` to `main`, `pull_request`, `workflow_dispatch`
- Jobs: Lint, Test, Security
- Runner: `ubuntu-22.04`
- Actions: `actions/checkout@v4`, `actions/cache@v4`
- Permissions: `contents: read`
- Caching: `.cache/ci-tools` (pinned `shellcheck` + `shfmt`)
- Timeouts: 15 minutes per job
- Concurrency: `ci-${{ github.workflow }}-${{ github.ref }}` (cancel in progress)

### Recent runs / failures
GitHub Actions API query (unauthenticated) returned one run on 2026-01-31 with conclusion `success`. No failed runs were found to analyze.

### Findings and fix plan
| Workflow | Failure(s) | Root cause | Fix plan | Risk | How to verify | Status |
| --- | --- | --- | --- | --- | --- | --- |
| CI | No failing runs found | Missing CI hardening and documentation (timeouts, concurrency, caching, tool pinning strategy, decision docs) | Added tool installer + cache, timeouts, concurrency, explicit triggers, and docs | Low | Run `make ci` locally; rerun CI on PR/push | Fixed |

---

## Findings

**Legend:** P0 = Critical / high impact, P1 = Major, P2 = Moderate, P3 = Low.

### P2
- **Missing security scans in CI (Secret/SCA)**  
  - Location: `.github/workflows/ci.yml`  
  - Expected: CI runs at least one secret scan and dependency scan (or documents why not applicable).  
  - Actual: CI only ran lint and tests.  
  - Fix: Added local secret scan and dependency-manifest gate; wired into CI.  
  - Verification: `./scripts/security.sh` passes; CI runs `./scripts/security.sh`.  
  - Status: Fixed.

- **CI runner not pinned to a specific Ubuntu version**  
  - Location: `.github/workflows/ci.yml` (`runs-on: ubuntu-latest`)  
  - Expected: Pinned runner for repeatability.  
  - Actual: `ubuntu-latest` could change.  
  - Fix: Pinned `runs-on` to `ubuntu-22.04`.  
  - Status: Fixed.

- **GitHub Actions not pinned to commit SHA**  
  - Location: `.github/workflows/ci.yml`  
  - Expected: Actions pinned to full commit SHA for supply-chain hardening.  
  - Actual: `actions/checkout@v4` was tag-pinned only.  
  - Fix: Pinned to specific commit SHA.  
  - Status: Fixed.

- **Test coverage gaps for fallback and service-start paths**  
  - Location: `tests/run.sh`  
  - Expected: Tests cover fallback update path and service start when no update but service inactive.  
  - Actual: Only three scenarios were covered.  
  - Fix: Added test cases with `REMOTE_BUILDID` empty and inactive service.  
  - Status: Fixed.

### P3
- **Unused command requirement**  
  - Location: `update_cs2.sh` (`require_cmd grep`)  
  - Expected: Only require commands that are used.  
  - Fix: Removed `require_cmd grep`.  
  - Status: Fixed.

---

## CI decision (2026-02-06)

**Decision:** FULL CI (lint, test, security on every PR and push).

### Rationale
- Repo contains executable update logic (`update_cs2.sh`) and deterministic tests under `tests/`.
- No production secrets or live infrastructure required for checks.
- Runtime is short (< 2 minutes), suitable for every PR and push to `main`.
- Checks reduce regression risk for service restart and update detection.

### What runs where
- Pull requests (including forks): Lint, tests, secret scan (no secrets).
- Push to `main`: Same as PR checks.
- Manual (`workflow_dispatch`): Same (for debugging).

### CI threat model
- Untrusted PRs: Only `pull_request` event (no `pull_request_target`).
- No secrets in PR jobs; workflow needs `contents: read` only.
- External downloads: `shellcheck` and `shfmt` from GitHub Releases with pinned versions and SHA256 verification.
- No write permissions, deployments, or artifact publishing.

### Limits and assumptions
- Integration tests requiring real SteamCMD, systemd, or live servers are not run on GitHub-hosted runners.
- Tool versions pinned in `scripts/ci-tools-versions.env`; updates require an explicit change.

### If deeper CI is needed later
- Add self-hosted runner with SteamCMD + systemd for real update/rollback testing.
- Split long-running integration tests into scheduled or manual workflows.
- Add SCA tooling if dependency manifests are introduced.
