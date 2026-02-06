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
require_cmd sha256sum

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

    if [ "$os" = "darwin" ] && [ "$arch" = "aarch64" ]; then
        echo "No official shellcheck macOS arm64 binary in older releases. Install via Homebrew." >&2
        exit 2
    fi

    local filename url sha_url tmpdir
    filename="shellcheck-v${SHELLCHECK_VERSION}.${os}.${arch}.tar.xz"
    url="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${filename}"
    sha_url="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${filename}.sha256"

    tmpdir="$(mktemp -d)"

    echo "Downloading shellcheck $SHELLCHECK_VERSION..."
    curl -fsSL "$url" -o "$tmpdir/$filename"
    curl -fsSL "$sha_url" -o "$tmpdir/$filename.sha256"

    local expected
    expected=$(awk '{print $1}' "$tmpdir/$filename.sha256")
    echo "${expected}  $tmpdir/$filename" | sha256sum -c - > /dev/null

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
    sha_url="https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/${filename}.sha256"

    tmpdir="$(mktemp -d)"

    echo "Downloading shfmt $SHFMT_VERSION..."
    curl -fsSL "$url" -o "$tmpdir/$filename"
    curl -fsSL "$sha_url" -o "$tmpdir/$filename.sha256"

    local expected
    expected=$(awk '{print $1}' "$tmpdir/$filename.sha256")
    echo "${expected}  $tmpdir/$filename" | sha256sum -c - > /dev/null

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
