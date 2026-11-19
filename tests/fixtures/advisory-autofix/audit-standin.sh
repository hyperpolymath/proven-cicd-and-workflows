#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Stand-in for `cargo deny check advisories` (the repo's pattern: stand-in
# oracles in self-tests, the live tool in the live control). It replays the
# RECORDED real cargo-deny output (deny-smallvec-1.6.0.jsonl) when the
# directory's Cargo.lock pins smallvec < 1.6.1, and is clean otherwise.
# STANDIN_NO_PATCH=1 replays the recorded no-patch form instead.
# STANDIN_TWO=1 reports TWO advisories on the same crate (ADV-A patched in
# 1.6.1, ADV-B patched in 1.7.0), each shown only while the lock is below its
# patch: the case where one bump per advisory against a stale locked version
# breaks.
dir="$1"; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ver="$(awk '/^name = "smallvec"/{getline; gsub(/[^0-9.]/,"",$0); print; exit}' "$dir/Cargo.lock")"
[ -n "$ver" ] || exit 0
below() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; }
emit() { # <id> <solution> : the recorded diagnostic with this id/solution/version
  sed "s/smallvec 1\.6\.0/smallvec $ver/; s/\"version\":\"1\.6\.0\"/\"version\":\"$ver\"/" "$here/deny-smallvec-1.6.0.jsonl" \
    | jq -c --arg id "$1" --arg s "Solution: $2" 'select(.type=="diagnostic") | .fields.advisory.id=$id | .fields.notes |= map(if startswith("Solution:") then $s else . end)' >&2
}
if [ "${STANDIN_TWO:-}" = 1 ]; then
  rc=0
  if below "$ver" 1.6.1; then emit ADV-A 'Upgrade to >=1.6.1'; rc=1; fi
  if below "$ver" 1.7.0; then emit ADV-B 'Upgrade to >=1.7.0'; rc=1; fi
  exit $rc
fi
if below "$ver" 1.6.1; then
  f="$here/deny-smallvec-1.6.0.jsonl"; [ "${STANDIN_NO_PATCH:-}" = 1 ] && f="$here/deny-no-patch.jsonl"
  sed "s/smallvec 1\.6\.0/smallvec $ver/; s/\"version\":\"1\.6\.0\"/\"version\":\"$ver\"/" "$f" >&2
  exit 1
fi
exit 0
