#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Stand-in for `cargo deny check advisories` (the repo's pattern: stand-in
# oracles in self-tests, the live tool in the live control). It replays the
# RECORDED real cargo-deny output (deny-smallvec-1.6.0.jsonl) when the
# directory's Cargo.lock pins smallvec < 1.6.1, and is clean otherwise.
# STANDIN_NO_PATCH=1 replays the recorded no-patch form instead.
dir="$1"; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ver="$(awk '/^name = "smallvec"/{getline; gsub(/[^0-9.]/,"",$0); print; exit}' "$dir/Cargo.lock")"
[ -n "$ver" ] || exit 0
if [ "$(printf '%s\n1.6.1\n' "$ver" | sort -V | head -n1)" = "$ver" ] && [ "$ver" != 1.6.1 ]; then
  f="$here/deny-smallvec-1.6.0.jsonl"; [ "${STANDIN_NO_PATCH:-}" = 1 ] && f="$here/deny-no-patch.jsonl"
  sed "s/smallvec 1\.6\.0/smallvec $ver/; s/\"version\":\"1\.6\.0\"/\"version\":\"$ver\"/" "$f" >&2
  exit 1
fi
exit 0
