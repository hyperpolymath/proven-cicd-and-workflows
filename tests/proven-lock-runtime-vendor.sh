#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Provenance of the vendored Idris2 RefC runtime (dist/proven-lock/runtime).
#
#   1. offline   SHA256SUMS lists exactly the .c/.h files present under refc/ and
#                c/, and every sum matches; LICENSE and UPSTREAM are present;
#                c/getline.c still carries its own NetBSD notice. A planted
#                one-byte change must fail the sums (negative control).
#   2. upstream  idris-lang/Idris2 at the commit UPSTREAM names: its .c/.h files
#                under support/refc and support/c (not support/c/windows) are
#                exactly the vendored set, each byte-identical, and LICENSE is
#                identical. A planted one-byte change must fail the comparison.
#
# UPSTREAM_DIR: an existing Idris2 checkout at that commit (else it is fetched).
# Exit: 0 conforms; 1 a file differs or is missing; 2 NOT RUN (no sha256sum or
# git, or upstream could not be fetched). A failed fetch is never a pass.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
rt=$root/dist/proven-lock/runtime
command -v sha256sum >/dev/null || { echo "proven-lock-runtime-vendor: sha256sum missing; NOT RUN" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL $*"; fail=1; }

# --- 1. offline
for f in LICENSE UPSTREAM SHA256SUMS; do [[ -f $rt/$f ]] || bad "dist/proven-lock/runtime/$f is missing"; done
[[ $fail == 0 ]] || exit 1
sha=$(sed -n 's/^# commit: *\([0-9a-f]\{40\}\)$/\1/p' "$rt/UPSTREAM")
[[ $sha =~ ^[0-9a-f]{40}$ ]] || { bad "UPSTREAM names no 40-hex commit"; exit 1; }
listed=$(awk '{print $2}' "$rt/SHA256SUMS" | LC_ALL=C sort)
present=$(cd "$rt" && find refc c -type f | LC_ALL=C sort)
[[ $listed == "$present" ]] && ok "SHA256SUMS lists exactly the $(wc -l <<<"$present") vendored files" ||
  bad "SHA256SUMS and the files differ: $(diff <(echo "$listed") <(echo "$present") | grep '^[<>]' | tr '\n' ' ')"
grep -qvE '\.(c|h)$' <<<"$present" && bad "a vendored file is not .c or .h: $(grep -vE '\.(c|h)$' <<<"$present" | tr '\n' ' ')"
(cd "$rt" && sha256sum --quiet -c SHA256SUMS) && ok 'every vendored file matches its sum' || bad 'a vendored file does not match SHA256SUMS'
grep -q 'The NetBSD Foundation' "$rt/c/getline.c" && ok 'c/getline.c keeps its NetBSD notice' || bad 'c/getline.c lost its NetBSD notice'
# Negative control: one changed byte must fail the sums.
cp -R "$rt" "$tmp/planted"
printf 'X' | dd of="$tmp/planted/refc/runtime.c" bs=1 seek=0 conv=notrunc status=none
if (cd "$tmp/planted" && sha256sum --quiet -c SHA256SUMS) >/dev/null 2>&1; then bad 'control: a one-byte change passed the sums'
else ok 'control: a one-byte change fails the sums'; fi

# --- 2. upstream
up=${UPSTREAM_DIR:-}
if [[ -z $up ]]; then
  command -v git >/dev/null || { echo "proven-lock-runtime-vendor: git missing; upstream check NOT RUN" >&2; exit 2; }
  up=$tmp/idris2
  git init -q "$up"
  git -C "$up" remote add origin https://github.com/idris-lang/Idris2.git
  git -C "$up" config core.sparseCheckout true
  printf 'support/refc/\nsupport/c/\n/LICENSE\n' > "$up/.git/info/sparse-checkout"
  fetched=0
  for delay in 0 5 15; do
    sleep "$delay"
    git -C "$up" fetch -q --depth=1 origin "$sha" 2>/dev/null && { fetched=1; break; }
  done
  [[ $fetched == 1 ]] && git -C "$up" checkout -q --detach FETCH_HEAD 2>/dev/null || {
    echo "proven-lock-runtime-vendor: could not fetch idris-lang/Idris2 at $sha; upstream check NOT RUN" >&2; exit 2; }
fi
[[ $(git -C "$up" rev-parse HEAD 2>/dev/null) == "$sha" ]] || { bad "the upstream checkout is not at $sha"; exit 1; }
upstream=$(cd "$up/support" && find refc c -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' \) | LC_ALL=C sort)
[[ $upstream == "$present" ]] && ok "the vendored set is exactly upstream's .c/.h under support/refc and support/c" ||
  bad "vendored and upstream sets differ: $(diff <(echo "$present") <(echo "$upstream") | grep '^[<>]' | tr '\n' ' ')"
same() { # VENDORED_DIR -> 0 when every file and LICENSE is byte-identical to upstream
  local d=$1 f
  cmp -s "$d/LICENSE" "$up/LICENSE" || return 1
  while IFS= read -r f; do cmp -s "$d/$f" "$up/support/$f" || return 1; done <<<"$present"
}
same "$rt" && ok "every vendored file and LICENSE is byte-identical to idris-lang/Idris2@${sha:0:12}" ||
  bad "a vendored file or LICENSE differs from idris-lang/Idris2@${sha:0:12}"
if same "$tmp/planted"; then bad 'control: a one-byte change passed the upstream comparison'
else ok 'control: a one-byte change fails the upstream comparison'; fi

exit "$fail"
