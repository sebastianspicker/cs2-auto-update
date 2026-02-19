#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/shell-files.env
source scripts/shell-files.env

echo "==> bash -n"
bash -n "${FILES[@]}"

if command -v shellcheck > /dev/null 2>&1; then
    echo "==> shellcheck"
    shellcheck -x "${FILES[@]}"
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
    shfmt -i 4 -ci -bn -sr -d "${FILES[@]}"
else
    cat << 'EOF' >&2
shfmt not found.

Install:
  - Ubuntu/Debian: sudo apt-get update && sudo apt-get install -y shfmt
  - macOS (Homebrew): brew install shfmt
EOF
    exit 2
fi
