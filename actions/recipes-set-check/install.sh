#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Pinned install of `just`; no floating release resolution.
#
# The gate used to pipe the upstream install script into bash. That script
# asks the GitHub API for the latest release at run time, so an unauthenticated
# rate limit or a slow response failed the gate, and the caller discarded the
# installer's output, so the log never said why. A pinned archive needs no API
# call, is checked against the publisher's SHA-256, and retries.
#
# Runners: Linux and macOS, x86_64 and arm64 -- the four the upstream script
# served that GitHub hosts. Each arm pins its own asset and checksum, taken
# from the SHA256SUMS file published with the release. Anything else exits 2,
# and the gate then fails as "verified nothing" unless `just` is already on
# PATH.
set -euo pipefail
destination=${1:?destination directory required}
version=1.43.0
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64)
        target=x86_64-unknown-linux-musl
        checksum=a1bc93654f31669fd964ea3011a5e5e9676b9b6f8adcd762606e5140632ea72d ;;
    Linux/aarch64 | Linux/arm64)
        target=aarch64-unknown-linux-musl
        checksum=4fcd8310081c32742eb984b1fdd0eee2e5d4d0f1be9629318012d42606ec9b3e ;;
    Darwin/x86_64)
        target=x86_64-apple-darwin
        checksum=687f66a6bd4d7d946ef5ff1e3efebb3d39dadad151a8c6b1de884cc93adc06a5 ;;
    Darwin/arm64)
        target=aarch64-apple-darwin
        checksum=bb0d35f6ca04709b798a19217693c16f4086170c580cc3b5c2531ad2794d2e32 ;;
    *)
        echo "unsupported runner $(uname -s)/$(uname -m): just ${version} is pinned for Linux and macOS on x86_64 and arm64" >&2
        exit 2 ;;
esac
mkdir -p "$destination"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base=https://github.com/casey/just/releases/download
# Bounded well inside a five-minute job. --max-time caps each attempt at 60 s.
# --retry-max-time is a clock that starts before the first attempt: no retry
# STARTS after 60 s, but one already running may finish, so the worst case is
# about 120 s.
curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --connect-timeout 10 --max-time 60 \
    --retry 2 --retry-max-time 60 \
    "${base}/${version}/just-${version}-${target}.tar.gz" \
    -o "$tmp/just.tar.gz" || {
        rc=$?
        printf 'just download failed (curl exit %s)\n' "$rc" >&2
        exit "$rc"
    }
# macOS ships shasum, not sha256sum.
if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$checksum" "$tmp/just.tar.gz" | sha256sum -c - >&2
else
    printf '%s  %s\n' "$checksum" "$tmp/just.tar.gz" | shasum -a 256 -c - >&2
fi
tar -xzf "$tmp/just.tar.gz" -C "$tmp" just
install -m 0755 "$tmp/just" "$destination/just"
"$destination/just" --version
