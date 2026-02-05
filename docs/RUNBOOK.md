# RUNBOOK

## Purpose
Local developer and CI runbook for this repository.

## Prerequisites
- Bash 4+ (macOS or Linux)
- `make`
- For lint/format: `shellcheck`, `shfmt`
- For production use of `update_cs2.sh`: `steamcmd`, `systemctl`, and a configured `steam` user

## Setup
No build step is required. Clone the repo and run scripts directly.

## Format
```bash
make fmt
```
Runs `shfmt` on Bash scripts. Requires `shfmt` installed.

## Lint / Static Checks
```bash
make lint
```
Runs `bash -n`, `shellcheck`, and `shfmt -d` (diff check).

## Tests
```bash
make test
```
Runs `./tests/run.sh` which uses stubbed binaries (no Steam or systemd needed).

## Build
Not applicable (shell script repository).

## Security Minimum
- Secret scan: `make security` runs a local regex-based scan for common secret patterns.
- SAST: `shellcheck` via `make lint`.
- SCA / dependency scan: `make security` fails if dependency manifests are present without a scanner configured.

## Fast Loop
```bash
make lint
make test
```

## Full Loop
```bash
make ci
```

## Troubleshooting
- `shellcheck not found` or `shfmt not found`: install per `./scripts/lint.sh` output.
- Tests failing on non-root systems: `tests/run.sh` already sets `ALLOW_NONROOT=1`.
- `steamcmd` missing for production run: install SteamCMD and set `STEAMCMD` if non-standard.
