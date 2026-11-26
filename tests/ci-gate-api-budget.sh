#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# tests/ci-gate-api-budget.sh - a bench: REST requests BILLED against the repository's GITHUB_TOKEN budget
# per gate evaluation, before (the publisher at BASE, default origin/main) and after (this tree's
# publisher, whose reads and writes go through the one REST layer, scripts/ci-gate-api.sh). Both run against the same fake GitHub (the stub of
# tests/ci-gate.sh), so the difference is the request pattern only.
#
# Billing model (GitHub's, for the primary limit): every request counts, including errors, except a
# 304 Not Modified answer to a conditional request; `gh api --paginate` costs one request per page of
# 100; `gh api rate_limit` is free. The suite-file fetch of the workflow is counted from the workflow
# itself (one contents request per `fetch`, or none when the git route works).
#
# It asserts only that AFTER never bills more than BEFORE in any scenario, and prints the table.
# Usage: bash tests/ci-gate-api-budget.sh [BASE]
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE=${1:-origin/main}
FX="$ROOT/tests/fixtures/ci-gate"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
FAIL=0

# the fake GitHub: the heredoc of tests/ci-gate.sh, verbatim
mkdir -p "$WORK/inner" "$WORK/bin"
awk '/^cat > "\$FAKEGH\/bin\/gh" <<.FAKEGH_EOF.$/ { on = 1; next } /^FAKEGH_EOF$/ { on = 0 } on' "$ROOT/tests/ci-gate.sh" > "$WORK/inner/gh"
[[ -s $WORK/inner/gh ]] || { echo "could not extract the fake gh from tests/ci-gate.sh"; exit 1; }
chmod +x "$WORK/inner/gh"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
# billing front: runs the fake, then appends the billed request count to $BILL
inner="$INNER/gh"
if [[ " $* " == *" -i "* ]]; then
  out=$("$inner" "$@"); rc=$?
  code=$(head -n 1 <<< "$out" | awk '{print $2}')
  [[ $code == 304 ]] && echo "0 $code $*" >> "$BILL" || echo "1 $code $*" >> "$BILL"
  printf '%s\n' "$out"; exit "$rc"
fi
if [[ " $* " == *" rate_limit "* ]]; then exec "$inner" "$@"; fi
out=$("$inner" "$@"); rc=$?
n=1
if [[ " $* " == *" --paginate "* ]]; then
  lines=$(grep -c . <<< "$out"); n=$(( (lines + 99) / 100 )); ((n >= 1)) || n=1
fi
echo "$n paginate $*" >> "$BILL"
printf '%s\n' "$out"; exit "$rc"
EOF
chmod +x "$WORK/bin/gh"

suite() { # <dir> <publisher source>
  mkdir -p "$1/scripts" "$1/profiles/ci-gate/example"
  cp "$ROOT"/scripts/ci-gate-verdict.sh "$ROOT"/scripts/validate-ci-gate-profile.sh "$1/scripts/"
  cp "$2" "$1/scripts/ci-gate-publish.sh"
  cp "$ROOT"/profiles/ci-gate/validate.jq "$ROOT"/profiles/ci-gate/select-runs.jq "$1/profiles/ci-gate/"
  cp "$FX/profile.json" "$1/profiles/ci-gate/example/repo.json"
}
git -C "$ROOT" show "$BASE:scripts/ci-gate-publish.sh" > "$WORK/old-publish.sh" || { echo "no publisher at $BASE"; exit 1; }
suite "$WORK/before" "$WORK/old-publish.sh"
suite "$WORK/after" "$ROOT/scripts/ci-gate-publish.sh"
# each side sources the layer its own workflow writes (CI_GATE_STATUS_LIB): BASE's status writer, this tree's REST layer
heredoc() { awk '/<<.CI_GATE_STATUS_EOF.$/{f=1;next} /^ *CI_GATE_STATUS_EOF$/{f=0} f' | sed 's/^          //'; }
git -C "$ROOT" show "$BASE:.github/workflows/ci-gate.yml" | heredoc > "$WORK/before-lib.sh"
heredoc < "$ROOT/.github/workflows/ci-gate.yml" > "$WORK/after-lib.sh"
[[ -s $WORK/before-lib.sh && -s $WORK/after-lib.sh ]] || { echo "could not extract the status writer / REST layer from the workflows"; exit 1; }

T0=$(date -u -d '2026-11-17T10:00:00Z' +%s); NOW=$((T0 + 30 * 60)); SHA=$(printf 'a%.0s' $(seq 40))
scenario() { # <runs jq over the fixture> -> a fresh fake GitHub state in $WORK/gh
  rm -rf "$WORK/gh"; mkdir -p "$WORK/gh"
  jq -c "$1" "$FX/workflow-runs.json" > "$WORK/gh/runs.1.json"; cp "$FX/jobs.json" "$WORK/gh/jobs.json"
  echo 0 > "$WORK/gh/clock"; : > "$WORK/gh/sleeps"
}
billed() { # <before|after> -> billed requests of one publisher invocation
  : > "$WORK/bill"; rm -rf "$WORK/pw"
  env PATH="$WORK/bin:$PATH" INNER="$WORK/inner" BILL="$WORK/bill" FAKEGH_DIR="$WORK/gh" REPO=example/repo HEAD_SHA="$SHA" \
    CONTEXT=CI/gate TIMEOUT_MINUTES=180 GATE_NAME='CI gate' SUITE="$WORK/$1" CI_GATE_STATUS_LIB="$WORK/$1-lib.sh" WORK="$WORK/pw" CI_GATE_NOW="$NOW" \
    CI_GATE_CLOCK="$WORK/clock" CI_GATE_SLEEP="$WORK/nap" GITHUB_OUTPUT="$WORK/gho" GITHUB_STEP_SUMMARY="$WORK/gss" \
    bash "$WORK/$1/scripts/ci-gate-publish.sh" > "$WORK/$1.out" 2>&1
  echo "$?:$(awk '{ s += $1 } END { print s + 0 }' "$WORK/bill")"
}
printf '#!/usr/bin/env bash\ncat "%s/gh/clock"\n' "$WORK" > "$WORK/clock"
printf '#!/usr/bin/env bash\necho $(( $(cat "%s/gh/clock") + $1 )) > "%s/gh/clock"\n' "$WORK" "$WORK" > "$WORK/nap"
chmod +x "$WORK/clock" "$WORK/nap"

# 344 extra completed `CI gate` runs on the same head: what proven-cicd's main head carried (348 in all)
BUSY='. + [range(344) as $i | .[3] | .id = 5000 + $i | .created_at = "2026-11-17T10:05:00Z"]'
ACTIVE='map(if .id == 12 then .status = "in_progress" | .conclusion = null else . end)'

old_fetch=$(git -C "$ROOT" show "$BASE:.github/workflows/ci-gate.yml" | grep -cE '^ +fetch [a-z]')
new_fetch_api=$(grep -cE '^ +fetch [a-z]' "$ROOT/.github/workflows/ci-gate.yml")
grep -q 'git -C "$git_dir" -c protocol.version=2 fetch' "$ROOT/.github/workflows/ci-gate.yml" && new_fetch=0 || new_fetch=$new_fetch_api

printf '\n%-58s %8s %8s\n' "billed REST requests per gate job" before after
row() { # <label> <before> <after>
  printf '%-58s %8s %8s\n' "$1" "$2" "$3"
  (( $3 <= $2 )) || { echo "  FAIL after bills more than before: $1"; FAIL=1; }
}
row "suite files (workflow fetch step; git route = 0)" "$old_fetch" "$new_fetch"
for s in "settled, 4 runs on the head:." "a required run still active:$ACTIVE" "settled, 348 runs on the head (main-head case):$BUSY"; do
  label=${s%%:*}; jqf=${s#*:}
  scenario "$jqf"; b=$(billed before); scenario "$jqf"; a=$(billed after)
  [[ ${b%%:*} == "${a%%:*}" ]] || { echo "  FAIL exit codes differ for '$label': before ${b%%:*}, after ${a%%:*}"; FAIL=1; }
  diff <(grep -E 'state=|::error::' "$WORK/before.out" | sed 's/[0-9]\+s//g' | head -n 3) <(grep -E 'state=|::error::' "$WORK/after.out" | sed 's/[0-9]\+s//g' | head -n 3) > /dev/null \
    || { echo "  note: outputs differ for '$label' (see the run logs)"; }
  row "publisher: $label" "${b#*:}" "${a#*:}"
  [[ -z ${BENCH_VERBOSE:-} ]] || { echo "    before:"; sed "s/^/      /" "$WORK/before.out" | grep -E "state|CI/gate" | head -3; echo "    after:"; sed "s/^/      /" "$WORK/after.out" | grep -E "state|CI/gate" | head -3; awk "{print \"      \" \$1, \$2, \$NF}" "$WORK/bill"; }
done
echo
((FAIL == 0)) && echo "ci-gate-api-budget: after <= before in every scenario" || echo "ci-gate-api-budget: FAILED"
((FAIL == 0))
