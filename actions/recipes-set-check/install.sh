#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Pinned Linux x64 install of `just`; no floating release resolution.
#
# The gate used to pipe the upstream install script into bash. That script
# asks the GitHub API for the latest release at run time, so an unauthenticated
# rate limit or a slow response failed the gate, and the caller discarded the
# installer's output, so the log never said why. A pinned archive needs no API
# call, is checked against the publisher's SHA-256, and retries.
set -euo pipefail
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'unsupported runner architecture' >&2; exit 2; }
destination=${1:?destination directory required}
mkdir -p "$destination"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
version=1.43.0
checksum=a1bc93654f31669fd964ea3011a5e5e9676b9b6f8adcd762606e5140632ea72d
base=https://github.com/casey/just/releases/download
curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --connect-timeout 10 --max-time 90 \
    --retry 2 --retry-max-time 180 \
    "${base}/${version}/just-${version}-x86_64-unknown-linux-musl.tar.gz" \
    -o "$tmp/just.tar.gz"
printf '%s  %s\n' "$checksum" "$tmp/just.tar.gz" | sha256sum -c - >&2
tar -xzf "$tmp/just.tar.gz" -C "$tmp" just
install -m 0755 "$tmp/just" "$destination/just"
"$destination/just" --version
