#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# proven-run.sh CATEGORY LANG DIR COMMAND
#
# Runs one category command and refuses a vacuous pass: a test run that
# executed zero tests is a failure (ER-A8, no pass on absence). Exit status:
# 0 ran and passed, 1 failed or ran nothing, 2 could not run.
set -uo pipefail
cat=${1:?category} lang=${2:?lang} dir=${3:?dir} cmd=${4:?command}
[[ -d $dir ]] || { echo "::error::proven-run: directory $dir does not exist"; exit 2; }
out=$(mktemp); trap 'rm -f "$out"' EXIT
prep=""
case $lang in
  elixir) prep="mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get" ;;
  node)   prep="npm ci" ;;
  go)     prep="go mod download" ;;
  python) prep="python -m pip install -q -e . 2>/dev/null || python -m pip install -q -r requirements.txt 2>/dev/null || true; python -m pip install -q pytest" ;;
  *) ;;
esac
if [[ -n $prep ]]; then
  ( cd "$dir" && bash -o pipefail -c "$prep" ) || { echo "::error::proven $cat/$lang: dependency preparation failed"; exit 1; }
fi
echo "proven-run: $cat/$lang in $dir: $cmd"
( cd "$dir" && bash -o pipefail -c "$cmd" ) 2>&1 | tee "$out"
rc=${PIPESTATUS[0]}
if [[ $rc -ne 0 ]]; then
  echo "::error::proven $cat/$lang failed (exit $rc)"; exit 1
fi
# Build is not a test run; every other category must have executed something.
[[ $cat == build ]] && exit 0
ran=unknown
case $lang in
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
[[ $ran == unknown ]] && echo "::notice::proven $cat/$lang: zero-test detection has no parser for $lang; exit status only"
exit 0
