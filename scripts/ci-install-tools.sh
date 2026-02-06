#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="$ROOT_DIR/scripts/ci-tools-versions.env"

if [ ! -f "$VERSIONS_FILE" ]; then
    echo "Missing versions file: $VERSIONS_FILE" >&2
    exit 2
fi

# shellcheck source=/dev/null
. "$VERSIONS_FILE"

CI_TOOLS_DIR="${CI_TOOLS_DIR:-$ROOT_DIR/.cache/ci-tools}"
BIN_DIR="$CI_TOOLS_DIR/bin"

mkdir -p "$BIN_DIR"

echo "Using CI tools dir: $CI_TOOLS_DIR"

add_path() {
    if [ -n "${GITHUB_PATH:-}" ]; then
        echo "$BIN_DIR" >> "$GITHUB_PATH"
    else
        export PATH="$BIN_DIR:$PATH"
    fi
}

require_cmd() {
    local cmd
    cmd="$1"
    if ! command -v "$cmd" > /dev/null 2>&1; then
        echo "Missing required command: $cmd" >&2
        exit 2
    fi
}

require_cmd curl
require_cmd tar
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"

case "$os" in
    linux)
        os="linux"
        ;;
    darwin)
        os="darwin"
        ;;
    *)
        echo "Unsupported OS: $os. Install tools manually." >&2
        exit 2
        ;;
esac

case "$arch" in
    x86_64 | amd64)
        arch="x86_64"
        shfmt_arch="amd64"
        ;;
    arm64 | aarch64)
        arch="aarch64"
        shfmt_arch="arm64"
        ;;
    *)
        echo "Unsupported architecture: $arch. Install tools manually." >&2
        exit 2
        ;;
esac

sha256_file() {
    local file
    file="$1"
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
        return 0
    fi
    if command -v shasum > /dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
        return 0
    fi
    echo "Missing sha256sum or shasum for checksum verification." >&2
    exit 2
}

shellcheck_expected_sha() {
    case "${os}_${arch}" in
        linux_x86_64)
            echo "${SHELLCHECK_SHA256_LINUX_X86_64:-}"
            ;;
        linux_aarch64)
            echo "${SHELLCHECK_SHA256_LINUX_AARCH64:-}"
            ;;
        darwin_x86_64)
            echo "${SHELLCHECK_SHA256_DARWIN_X86_64:-}"
            ;;
        darwin_aarch64)
            echo "${SHELLCHECK_SHA256_DARWIN_AARCH64:-}"
            ;;
        *)
            echo ""
            ;;
    esac
}

install_shellcheck() {
    local current
    current=""
    if [ -x "$BIN_DIR/shellcheck" ]; then
        current=$("$BIN_DIR/shellcheck" --version 2> /dev/null | awk '/version:/ {print $2; exit}')
    fi

    if [ "$current" = "$SHELLCHECK_VERSION" ]; then
        echo "shellcheck $SHELLCHECK_VERSION already installed."
        return 0
    fi

    local filename url sha_url tmpdir
    filename="shellcheck-v${SHELLCHECK_VERSION}.${os}.${arch}.tar.xz"
    url="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${filename}"
    local expected
    expected=$(shellcheck_expected_sha)
    if [ -z "$expected" ]; then
        echo "Missing expected SHA256 for shellcheck on ${os}/${arch}. Update scripts/ci-tools-versions.env." >&2
        exit 2
    fi

    tmpdir="$(mktemp -d)"

    echo "Downloading shellcheck $SHELLCHECK_VERSION..."
    curl -fsSL "$url" -o "$tmpdir/$filename"
    if [ "$(sha256_file "$tmpdir/$filename")" != "$expected" ]; then
        echo "shellcheck checksum mismatch for $filename" >&2
        exit 2
    fi

    tar -xJf "$tmpdir/$filename" -C "$tmpdir"
    install -m 0755 "$tmpdir/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$BIN_DIR/shellcheck"
    rm -rf "$tmpdir"
    echo "Installed shellcheck $SHELLCHECK_VERSION."
}

install_shfmt() {
    local current
    current=""
    if [ -x "$BIN_DIR/shfmt" ]; then
        current=$("$BIN_DIR/shfmt" -version 2> /dev/null | tr -d 'v' | awk 'NR==1{print $1}')
    fi

    if [ "$current" = "$SHFMT_VERSION" ]; then
        echo "shfmt $SHFMT_VERSION already installed."
        return 0
    fi

    local filename url sha_url tmpdir
    filename="shfmt_v${SHFMT_VERSION}_${os}_${shfmt_arch}"
    url="https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/${filename}"
    sha_url="https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/sha256sums.txt"

    tmpdir="$(mktemp -d)"

    echo "Downloading shfmt $SHFMT_VERSION..."
    curl -fsSL "$url" -o "$tmpdir/$filename"
    curl -fsSL "$sha_url" -o "$tmpdir/sha256sums.txt"

    local expected
    expected=$(awk -v f="$filename" '$2==f {print $1}' "$tmpdir/sha256sums.txt")
    if [ -z "$expected" ]; then
        echo "Missing shfmt checksum for $filename in sha256sums.txt" >&2
        exit 2
    fi
    if [ "$(sha256_file "$tmpdir/$filename")" != "$expected" ]; then
        echo "shfmt checksum mismatch for $filename" >&2
        exit 2
    fi

    install -m 0755 "$tmpdir/$filename" "$BIN_DIR/shfmt"
    rm -rf "$tmpdir"
    echo "Installed shfmt $SHFMT_VERSION."
}

install_shellcheck
install_shfmt
add_path

echo "CI tools ready:"
"$BIN_DIR/shellcheck" --version | head -n 1
"$BIN_DIR/shfmt" -version
