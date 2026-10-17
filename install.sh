#!/usr/bin/env bash
# Provides the ipvault binary for this action: a caller-supplied one, or a release archive whose
# SHA-256 is pinned in checksums.txt beside this script. An unpinned version is refused: the
# point of pinning the action by commit is that it pins the binary too.
#
# The archive comes from the public release (no token), or, with IPVAULT_DOWNLOAD_REPO, from a
# GitHub release in a repository the job's token can read: a private mirror of the same archives.
# Either way the pinned checksum decides whether it runs.
#
# This file is shared verbatim by every ipvault action (ci/pin-release.py --check compares them).
set -euo pipefail

if [[ -n "${IPVAULT_PATH:-}" ]]; then
  [[ -x "$IPVAULT_PATH" ]] || { echo "::error::ipvault-path '$IPVAULT_PATH' is not an executable file"; exit 2; }
  echo "Using the supplied binary: $IPVAULT_PATH"
  echo "bin=$IPVAULT_PATH" >> "$GITHUB_OUTPUT"
  exit 0
fi

[[ "$IPVAULT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
  || { echo "::error::invalid version '$IPVAULT_VERSION'"; exit 2; }

case "${RUNNER_OS}/${RUNNER_ARCH}" in
  Linux/X64) target=x86_64-unknown-linux-musl ;;
  Linux/ARM64) target=aarch64-unknown-linux-musl ;;
  macOS/ARM64) target=aarch64-apple-darwin ;;
  macOS/X64) target=x86_64-apple-darwin ;;
  *) echo "::error::no ipvault build for ${RUNNER_OS}/${RUNNER_ARCH}; pass ipvault-path"; exit 2 ;;
esac

asset="ipvault-${IPVAULT_VERSION}-${target}.tar.gz"
expected="$(awk -v a="$asset" '$2 == a { print $1 }' "$GITHUB_ACTION_PATH/checksums.txt")"
if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
  echo "::error::no pinned checksum for $asset in this version of the action. Pin a newer action commit, or pass ipvault-path."
  exit 2
fi

dir="$RUNNER_TEMP/ipvault-$IPVAULT_VERSION-$target"
mkdir -p "$dir"
tag="v$IPVAULT_VERSION"
if [[ -n "${IPVAULT_DOWNLOAD_REPO:-}" ]]; then
  [[ "$IPVAULT_DOWNLOAD_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || { echo "::error::download-repo must be owner/name"; exit 2; }
  gh release download "$tag" --repo "$IPVAULT_DOWNLOAD_REPO" --pattern "$asset" --dir "$dir" --clobber
else
  base="https://github.com/rev3rse-dev/ipvault-cli/releases/download"
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$dir/$asset" "$base/$tag/$asset"
fi

if command -v sha256sum > /dev/null; then
  actual="$(sha256sum "$dir/$asset" | cut -d' ' -f1)"
else
  actual="$(shasum -a 256 "$dir/$asset" | cut -d' ' -f1)"
fi
if [[ "$actual" != "$expected" ]]; then
  echo "::error::checksum mismatch for $asset: got $actual, pinned $expected. Refusing to run it."
  exit 2
fi
echo "Verified $asset (sha256 $actual)"

tar -xzf "$dir/$asset" -C "$dir"
bin="$dir/ipvault-$IPVAULT_VERSION-$target/ipvault"
[[ -x "$bin" ]] || { echo "::error::$asset does not contain an ipvault binary"; exit 2; }
echo "bin=$bin" >> "$GITHUB_OUTPUT"
