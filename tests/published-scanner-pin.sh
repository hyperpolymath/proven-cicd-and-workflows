#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROBE_LOG"
[[ "$1" == api && "$2" == "repos/$EXPECTED_REPOSITORY/compare/$EXPECTED_PIN...main" && "$3" == --jq && "$4" == .status ]] || exit 99
[[ ${PROBE_FAILURE:-0} == 0 ]] || exit 1
echo "${COMPARISON-identical}"
MOCK
chmod +x "$tmp/gh"
export PATH="$tmp:$PATH"
# The compare-API cases below run with git unable to fetch (no such source), so they test the fallback.
export PIN_GIT_BASE="$tmp/no-such-source"
pin=0123456789abcdef0123456789abcdef01234567
export EXPECTED_PIN=$pin PROBE_LOG="$tmp/probe-log"
for repository in hyperpolymath/cicd-suite hyperpolymath/proven-cicd hyperpolymath/proven-cicd-and-workflows; do
  export EXPECTED_REPOSITORY=$repository
  for status in identical ahead behind diverged null unknown ''; do
    rc=0
    COMPARISON=$status bash "$root/scripts/verify-published-scanner-pin.sh" "$pin" "$repository" >"$tmp/out" 2>&1 || rc=$?
    case $status in
        identical|ahead) [[ $rc == 0 ]] ;;
        behind|diverged) [[ $rc == 1 ]] ;;
        *) [[ $rc == 2 ]] ;;
    esac
    echo "ok: publication guard handles $repository ($status)"
  done
  rc=0
  PROBE_FAILURE=1 bash "$root/scripts/verify-published-scanner-pin.sh" "$pin" "$repository" >"$tmp/out" 2>&1 || rc=$?
  [[ $rc == 2 ]]
done
export EXPECTED_REPOSITORY=hyperpolymath/cicd-suite
bash "$root/scripts/verify-published-scanner-pin.sh" "$pin" >/dev/null
for repository in attacker/proven-cicd hyperpolymath/proven-cicd-extra ''; do
  : > "$PROBE_LOG"
  rc=0
  bash "$root/scripts/verify-published-scanner-pin.sh" "$pin" "$repository" >"$tmp/out" 2>&1 || rc=$?
  [[ $rc == 2 && ! -s "$PROBE_LOG" ]]
done
rc=0
bash "$root/scripts/verify-published-scanner-pin.sh" main >"$tmp/out" 2>&1 || rc=$?
[[ $rc == 2 ]]
echo 'ok: publication guard refuses unavailable evidence and non-SHA refs'

# The git path: a local source with main = c1 <- c2, and a side commit s1 off c1.
src="$tmp/src/hyperpolymath/proven-cicd-and-workflows"
git init -q -b main "$src"
gc() { git -C "$src" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m "$1"; git -C "$src" rev-parse HEAD; }
c1=$(gc one); c2=$(gc two)
git -C "$src" switch -q -c side "$c1"; s1=$(gc side); git -C "$src" switch -q main
export PIN_GIT_BASE="$tmp/src" EXPECTED_REPOSITORY=none
r=hyperpolymath/proven-cicd-and-workflows
for case in "$c2:0:identical" "$c1:0:ahead" "$s1:1:diverged" "0123456789abcdef0123456789abcdef01234567:1:unknown"; do
  IFS=: read -r p want what <<<"$case"
  : > "$PROBE_LOG"; rc=0
  bash "$root/scripts/verify-published-scanner-pin.sh" "$p" "$r" >"$tmp/out" 2>&1 || rc=$?
  if [[ $rc != "$want" || -s "$PROBE_LOG" ]] || ! grep -q 'by git' "$tmp/out"; then
    echo "FAIL: git path, $what pin: rc=$rc"; cat "$tmp/out"; exit 1
  fi
  echo "ok: git path judges the $what pin (rc=$rc) with no API call"
done
# A long history: a recent pin with 3000 older commits behind it. grep finds the pin near the top
# of the commit list, far before the end of a list bigger than a pipe buffer (the SIGPIPE case).
git -C "$src" fast-import --quiet < <(
  for i in $(seq 1 3000); do
    printf 'commit refs/heads/main\ncommitter t <t@t> %d +0000\ndata 1\nx\n' "$((1700000000 + i))"
    [[ $i == 1 ]] && printf 'from %s\n' "$c2"
    printf '\n'
  done)
recent=$(gc recent); gc tip >/dev/null
: > "$PROBE_LOG"; rc=0
bash "$root/scripts/verify-published-scanner-pin.sh" "$recent" "$r" >"$tmp/out" 2>&1 || rc=$?
if [[ $rc != 0 || -s "$PROBE_LOG" ]]; then echo "FAIL: a recent pin over 3000 older commits: rc=$rc"; cat "$tmp/out"; exit 1; fi
echo "ok: git path finds a recent pin over 3000 older commits"
