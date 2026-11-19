#!/usr/bin/env bash
# Installs the tailcat CLI on a GitHub Actions runner and adds it to PATH.
#
# Env:
#   TAILCAT_VERSION  release tag (e.g. v0.7.0) or "latest" (default)
set -euo pipefail

version="${TAILCAT_VERSION:-latest}"
dest="${RUNNER_TEMP:-/tmp}/tailcat-bin"
mkdir -p "$dest"

if command -v tailcat >/dev/null 2>&1; then
  echo "tailcat already installed: $(command -v tailcat) ($(tailcat version 2>/dev/null || echo unknown))"
  exit 0
fi

case "${RUNNER_OS:-$(uname -s)}" in
  Linux)   os=linux ;;
  Windows|MINGW*|MSYS*|CYGWIN*) os=windows ;;
  macOS|Darwin) os=darwin ;;
  *) echo "::error::unsupported runner OS: ${RUNNER_OS:-$(uname -s)}"; exit 1 ;;
esac

case "${RUNNER_ARCH:-$(uname -m)}" in
  X64|x86_64|amd64)   arch=amd64 ;;
  ARM64|aarch64|arm64) arch=arm64 ;;
  ARM|armv7l)         arch=armv7 ;;
  *) echo "::error::unsupported runner arch: ${RUNNER_ARCH:-$(uname -m)}"; exit 1 ;;
esac

if [[ "$os" == darwin ]]; then
  # tailcat publishes no macOS release binaries; use Homebrew, else build with Go.
  if command -v brew >/dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install tailcat
    exit 0
  elif command -v go >/dev/null 2>&1; then
    ref="$version"
    GOBIN="$dest" go install "github.com/tailscale/tailcat/cmd/tailcat@${ref}"
    echo "$dest" >> "$GITHUB_PATH"
    exit 0
  fi
  echo "::error::macOS runner has neither brew nor go to install tailcat"; exit 1
fi

if [[ "$version" == latest ]]; then
  # The /releases/latest page redirects to /releases/tag/<tag>.
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/tailscale/tailcat/releases/latest)
  version="${url##*/}"
fi
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || { echo "::error::bad tailcat version: $version"; exit 1; }
num="${version#v}"

ext=tar.gz; [[ "$os" == windows ]] && ext=zip
asset="tailcat_${num}_${os}_${arch}.${ext}"
base="https://github.com/tailscale/tailcat/releases/download/${version}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading ${base}/${asset}"
curl -fsSL --retry 3 -o "$tmp/$asset" "${base}/${asset}"
curl -fsSL --retry 3 -o "$tmp/checksums.txt" "${base}/checksums.txt"

want=$(awk -v a="$asset" '$2 == a {print $1}' "$tmp/checksums.txt")
[[ -n "$want" ]] || { echo "::error::$asset not listed in checksums.txt"; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
  got=$(sha256sum "$tmp/$asset" | awk '{print $1}')
else
  got=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')
fi
[[ "$got" == "$want" ]] || { echo "::error::checksum mismatch for $asset"; exit 1; }

if [[ "$ext" == zip ]]; then
  unzip -q -o "$tmp/$asset" -d "$tmp/x"
  cp "$tmp/x/tailcat.exe" "$dest/"
else
  tar -xzf "$tmp/$asset" -C "$tmp"
  install -m 0755 "$tmp/tailcat" "$dest/tailcat"
fi

echo "$dest" >> "$GITHUB_PATH"
echo "Installed tailcat ${version} to $dest"
