#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

files=(
    update_cs2.sh
    scripts/lint.sh
    scripts/fmt.sh
    tests/run.sh
    tests/bin/df
    tests/bin/runuser
    tests/bin/steamcmd
    tests/bin/systemctl
)

echo "==> bash -n"
bash -n "${files[@]}"

if command -v shellcheck > /dev/null 2>&1; then
    echo "==> shellcheck"
    shellcheck -x "${files[@]}"
else
    cat << 'EOF' >&2
shellcheck not found.

Install:
  - Ubuntu/Debian: sudo apt-get update && sudo apt-get install -y shellcheck
  - macOS (Homebrew): brew install shellcheck
EOF
    exit 2
fi

if command -v shfmt > /dev/null 2>&1; then
    echo "==> shfmt (diff)"
    shfmt -i 4 -ci -bn -sr -d "${files[@]}"
else
    cat << 'EOF' >&2
shfmt not found.

Install:
  - Ubuntu/Debian: sudo apt-get update && sudo apt-get install -y shfmt
  - macOS (Homebrew): brew install shfmt
EOF
    exit 2
fi
