#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# proven-run.sh CATEGORY LANG DIR COMMAND
#
# Runs one category command and refuses a vacuous pass: a test run that
# executed zero tests is a failure (ER-A8, no pass on absence). Exit status:
# 0 ran and passed, 1 failed or ran nothing, 2 could not run.
set -uo pipefail
cat=${1:?category} lang=${2:?lang} dir=${3:?dir} cmd=${4:?command}
langs=${LANGS:-$lang}   # a merged "<category>-all" job lists every language it stands for
[[ -d $dir ]] || { echo "::error::proven-run: directory $dir does not exist"; exit 2; }
out=$(mktemp); trap 'rm -f "$out"' EXIT
# prep_for LANG: print the dependency-preparation command for LANG in $dir (empty = none); exit 1 if it cannot be reproducible
prep_for() {
  case $1 in
    elixir) echo "mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get" ;;
    node)   if   [[ -f $dir/bun.lock || -f $dir/bun.lockb ]]; then echo "command -v bun >/dev/null || npm install -g \"bun@${BUN_VERSION:?BUN_VERSION is not set}\"; bun install --frozen-lockfile"
            elif [[ -f $dir/pnpm-lock.yaml ]]; then echo "corepack enable pnpm && pnpm install --frozen-lockfile"
            elif [[ -f $dir/yarn.lock ]]; then echo "corepack enable yarn && yarn install --immutable"
            elif [[ -f $dir/package-lock.json ]]; then echo "npm ci"
            else echo "::error::proven $cat/$1: no lockfile (bun.lock, pnpm-lock.yaml, yarn.lock or package-lock.json) in $dir; a reproducible install is required" >&2; return 1
            fi ;;
    go)     echo "go mod download" ;;
    python) echo "python -m pip install -q -e . 2>/dev/null || python -m pip install -q -r requirements.txt 2>/dev/null || true; python -m pip install -q pytest" ;;
    *) ;;
  esac
}
for l in ${langs//,/ }; do
  [[ $l == all ]] && continue
  prep=$(prep_for "$l") || { echo "$prep"; exit 1; }
  if [[ -n $prep ]]; then
    ( cd "$dir" && bash -o pipefail -c "$prep" ) || { echo "::error::proven $cat/$l: dependency preparation failed"; exit 1; }
  fi
done
echo "proven-run: $cat/$lang in $dir: $cmd"
( cd "$dir" && bash -o pipefail -c "$cmd" ) 2>&1 | tee "$out"
rc=${PIPESTATUS[0]}
if [[ $rc -ne 0 ]]; then
  echo "::error::proven $cat/$lang failed (exit $rc)"; exit 1
fi
# Build is not a test run; every other category must have executed something.
[[ $cat == build ]] && exit 0
ran=unknown
zero_re_rust='^running [1-9][0-9]* tests?'
case $lang in
  zig)    grep -qE 'All [1-9][0-9]* tests? passed|[1-9][0-9]*/[1-9][0-9]* .*(OK|passed)' "$out" && ran=yes || ran=no ;;
  shell)  grep -qE '^(ok|PASS|ok:)([ :]|$)|^1\.\.[1-9]|[1-9][0-9]* tests? (run|passed)' "$out" && ran=yes || ran=no ;;
  all)    # one repo-wide command (justfile recipe, convention file or manifest): any recognised test-count line counts
          grep -v "no tests to run" "$out" | grep -qE "$zero_re_rust|[1-9][0-9]* tests?, 0 failures|^ok( [0-9]+)? - |^ok [0-9]+( |$)|^--- PASS:|^ok[[:space:]]+[^[:space:]]+[[:space:]]+[0-9.]+s|^1\.\.[1-9]|[1-9][0-9]* (passed|passing)|[1-9][0-9]* tests? (run|passed)|All [1-9][0-9]* tests? passed|# pass [1-9]" && ran=yes || ran=no ;;
  rust)   grep -qE '^running [1-9][0-9]* tests?' "$out" && ran=yes || ran=no ;;
  elixir) grep -qE '^[0-9]+ (doctests?, )?[1-9][0-9]* tests?,|[1-9][0-9]* tests?, 0 failures' "$out" && ran=yes || ran=no ;;
  go)     grep -E '^(ok|PASS)' "$out" | grep -qv 'no tests to run' && ran=yes || ran=no ;;
  python) grep -qE '[1-9][0-9]* passed' "$out" && ran=yes || ran=no ;;
  node)   grep -qE '(tests? |pass |# pass )[1-9][0-9]*|[1-9][0-9]* (passing|passed|pass)' "$out" && ran=yes || ran=no ;;
  *) ;;
esac
if [[ $ran == no ]]; then
  echo "::error::proven $cat/$lang: the command passed but ran zero tests; that is not a pass"; exit 1
fi
if [[ $ran == unknown ]]; then
  echo "::error::proven $cat/$lang: no zero-test parser for $lang, so a vacuous pass cannot be ruled out. Fail closed: add a parser here or give the command a test-count line"; exit 1
fi
exit 0
