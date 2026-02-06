# CI Audit

Date: 2026-02-06

## Workflow Inventory (Current)
- Workflow: `CI` (`.github/workflows/ci.yml`)
- Triggers: `push` to `main`, `pull_request`, `workflow_dispatch`
- Jobs: `Lint • Test • Security`
- Runner: `ubuntu-22.04`
- Actions: `actions/checkout@v4`, `actions/cache@v4`
- Permissions: `contents: read`
- Caching: `.cache/ci-tools` (pinned `shellcheck` + `shfmt`)
- Timeouts: `15` minutes per job
- Concurrency: `ci-${{ github.workflow }}-${{ github.ref }}` (cancel in progress)

## Recent Runs / Failures
GitHub Actions API query (unauthenticated) returned one run on 2026-01-31 with conclusion `success`. No failed runs were found to analyze.

## Findings and Fix Plan
| Workflow | Failure(s) | Root Cause | Fix Plan | Risk | How to Verify | Status |
| --- | --- | --- | --- | --- | --- | --- |
| CI | No failing runs found | Missing CI hardening and documentation (timeouts, concurrency, caching, tool pinning strategy, decision docs) | Added tool installer + cache, timeouts, concurrency, explicit triggers, and docs | Low | Run `make ci` locally; rerun CI on PR/push | Fixed |
