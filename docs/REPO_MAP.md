# REPO MAP

## Top-Level
- `update_cs2.sh`: Main production script. Entry point for update flow.
- `scripts/`: Developer tooling (lint/format).
- `tests/`: Lightweight Bash tests using stubbed system binaries.
- `Makefile`: Convenience targets for lint/format/test/ci.
- `.github/workflows/ci.yml`: GitHub Actions CI running lint and tests.
- `.github/ISSUE_TEMPLATE/`: Issue templates for bugs and feature requests.
- `.github/pull_request_template.md`: Pull request checklist.
- `.github/dependabot.yml`: Dependabot config for GitHub Actions updates.
- `CONTRIBUTING.md`, `SECURITY.md`: Contribution and security reporting guidelines.
- `.editorconfig`, `.gitattributes`, `.gitignore`: Repo hygiene and formatting rules.

## Key Flows
- Update decision flow:
  - Read local buildid from `steamapps/appmanifest_730.acf`.
  - Query remote buildid via `steamcmd +app_info_print`.
  - If buildids match, ensure service running and exit.
  - Otherwise, stop service, run update, start service.
- Locking and safety:
  - Atomic lock dir (`LOCKDIR`) prevents concurrent runs.
  - `trap cleanup EXIT` removes lock on normal/abnormal exit.
  - Disk space check before update.

## Scripts
- `scripts/lint.sh`: `bash -n`, `shellcheck`, and `shfmt -d` on tracked scripts.
- `scripts/fmt.sh`: `shfmt` auto-format.
- `scripts/security.sh`: Secret-pattern scan and dependency-manifest check.

## Tests
- `tests/run.sh`: Runs three scenarios using stubbed binaries in `tests/bin/`.
- `tests/bin/*`: Minimal stubs for `steamcmd`, `systemctl`, `df`, `runuser`.

## Hot Spots / Risk Areas
- Parsing `app_info_print` output for buildid: best-effort and format-sensitive.
- Service control and retries: depends on `systemctl` availability and service health.
- Running SteamCMD as `steam` user: depends on `runuser`/`su`/`sudo` availability.
