#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

files=(
    update_cs2.sh
    scripts/lint.sh
    scripts/fmt.sh
    scripts/security.sh
    tests/run.sh
    tests/bin/df
    tests/bin/runuser
    tests/bin/steamcmd
    tests/bin/systemctl
)

if ! command -v shfmt > /dev/null 2>&1; then
    echo "shfmt not found. Install it first (see scripts/lint.sh output)." >&2
    exit 2
fi

shfmt -i 4 -ci -bn -sr -w "${files[@]}"
