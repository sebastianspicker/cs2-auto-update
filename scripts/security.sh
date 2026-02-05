#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

secret_regex='(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{82}|-----BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY-----|xox[baprs]-[A-Za-z0-9-]{10,48}|sk_live_[0-9a-zA-Z]{24}|AIza[0-9A-Za-z_-]{35})'

if git ls-files -z | xargs -0 grep -nE "$secret_regex"; then
    echo "Potential secret material detected. Redact and remove before committing." >&2
    exit 1
fi

echo "Secret scan passed (no matches)."

manifests=(
    package.json
    package-lock.json
    pnpm-lock.yaml
    yarn.lock
    requirements.txt
    Pipfile
    Pipfile.lock
    pyproject.toml
    poetry.lock
    go.mod
    go.sum
    Gemfile
    Gemfile.lock
)

found_manifest=0
for manifest in "${manifests[@]}"; do
    if [ -f "$manifest" ]; then
        echo "Dependency manifest found: $manifest" >&2
        found_manifest=1
    fi
done

if [ "$found_manifest" -eq 1 ]; then
    echo "SCA not configured for dependency manifests. Add a dependency scanner." >&2
    exit 2
fi

echo "SCA check: no dependency manifests found."
