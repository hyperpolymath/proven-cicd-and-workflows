#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Controls for the stamped coverage collector (templates/proven-coverage-collect.yml,
# scripts/proven-coverage-collect.sh, scripts/coverdata-to-lcov.exs).
#   stamp     the template matches its stamp and the manifest entry; body edit = drift;
#             local-region edit = still matches
#   lint      read-only token, every uses: a full SHA, every job named and timed out,
#             no continue-on-error, a retention for the artifact, one artifact name
#   pin       a malformed pinned SHA -> exit 2 before any fetch
#   driver    exit codes: no languages -> 0 "nothing to collect"; a failing tool is
#             reported and still 0; usage/env/drift -> 2; never 1
#   real      tiny Rust, Mix and JS fixtures under tests/fixtures/proven-coverage/ run
#             for real when their toolchain is present: reports and sidecars exist
#             and parse, proven never exceeds raw. A missing toolchain is SKIPPED
#             and named, unless PROVEN_COV_REQUIRE_REAL=1 (then it fails).
# Elixir is looked for on PATH, then /opt/ex117/bin and /opt/otp27/bin.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "proven-coverage-collect: jq missing; NOT RUN" >&2; exit 2; }
command -v yq >/dev/null && yq --version | grep -q mikefarah || { echo "proven-coverage-collect: mikefarah yq missing; NOT RUN" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
template=$root/templates/proven-coverage-collect.yml
driver=$root/scripts/proven-coverage-collect.sh
stamp=$root/scripts/proven-stamp.sh
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL $*"; fail=1; }
skip() { if [[ ${PROVEN_COV_REQUIRE_REAL:-0} == 1 ]]; then bad "$* (required)"; else echo "SKIP: $*"; fi; }
expect_rc() { # NAME WANT CMD...
  local name=$1 want=$2 rc=0; shift 2
  "$@" >"$tmp/out" 2>&1 || rc=$?
  if [[ $rc == "$want" ]]; then ok "$name"; else bad "$name: wanted exit $want, got $rc"; sed 's/^/    /' "$tmp/out" | tail -15; fi
}

# --- stamp and manifest
expect_rc 'the template matches its stamp' 0 bash "$stamp" check "$template"
first=$(head -n 1 "$template")
entry=$(jq -c '.artifacts[] | select(.artifact == "proven-coverage-collect")' "$root/proven/manifest.json")
[[ -n $entry ]] || bad 'proven/manifest.json has no proven-coverage-collect entry'
[[ $(jq -r .version <<<"$entry") == 0.1.0 ]] && ok 'manifest version is 0.1.0' || bad 'manifest version is not 0.1.0'
want="# proven-cicd: proven-coverage-collect@0.1.0 sha256:$(jq -r .sha256 <<<"$entry")"
[[ $first == "$want" ]] && ok "the template's stamp line is the manifest's" || bad "stamp line '$first' is not the manifest's '$want'"
[[ $(jq -r .sha256 <<<"$entry") == "$(bash "$stamp" hash "$template")" ]] && ok 'manifest sha256 is the template body hash' || bad 'manifest sha256 is not the body hash'
[[ $(jq -r .template <<<"$entry") == templates/proven-coverage-collect.yml && $(jq -r .install_path <<<"$entry") == .github/workflows/proven-coverage-collect.yml ]] &&
  ok 'manifest template and install_path' || bad 'manifest template or install_path'
sed 's/timeout-minutes: 30/timeout-minutes: 90/' "$template" > "$tmp/edited.yml"
expect_rc 'a body edit is drift' 1 bash "$stamp" check "$tmp/edited.yml"
sed -e 's/PROVEN_SHA: "0\{40\}"/PROVEN_SHA: "1111111111111111111111111111111111111111"/' \
    -e 's/PROVEN_COV_RUST_PROVEN_FILTER: "prop_"/PROVEN_COV_RUST_PROVEN_FILTER: "check_"/' \
    -e 's/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1/checkout@2222222222222222222222222222222222222222 # v7.1.0/' \
    "$template" > "$tmp/local.yml"
grep -q 1111111111 "$tmp/local.yml" && grep -q 2222222222 "$tmp/local.yml" && grep -q 'check_' "$tmp/local.yml" || bad 'local-region control did not apply its edits'
expect_rc 'a local-region edit (suite pin, action bump, filter) still matches' 0 bash "$stamp" check "$tmp/local.yml"
for k in PROVEN_SHA PROVEN_COV_RUST_TOOLCHAIN PROVEN_COV_RUST_PROVEN_FILTER PROVEN_COV_JS_RAW_TESTS PROVEN_COV_JS_PROVEN_TESTS; do
  grep -B1 "^      $k:" "$template" | head -n 1 | grep -qx '      # proven-cicd:local-next' && ok "$k is a local-next value" || bad "$k is not under a local-next marker"
done
n_uses=$(grep -c '^      - uses:' "$template"); n_marked=$(grep -B1 '^      - uses:' "$template" | grep -c 'proven-cicd:local-next')
[[ $n_uses == "$n_marked" && $n_uses -ge 5 ]] && ok 'every third-party uses: line is a local-next value' || bad "uses lines $n_uses, marked $n_marked"

# --- lint
[[ $(yq -o json -I 0 '.permissions' "$template") == '{"contents":"read"}' ]] && ok 'token is read-only' || bad 'permissions are not exactly contents: read'
[[ $(yq '[.. | select(has("continue-on-error"))] | length' "$template") == 0 ]] && ok 'no continue-on-error (a broken collector fails the job)' || bad 'continue-on-error found'
[[ $(yq '[.jobs[] | select(has("name") | not)] | length' "$template") == 0 ]] && ok 'every job has an explicit name' || bad 'a job has no explicit name'
[[ $(yq '[.jobs[] | select(has("timeout-minutes") | not)] | length' "$template") == 0 ]] && ok 'every job has a timeout' || bad 'a job has no timeout'
if yq '.. | select(has("uses")) | .uses' "$template" | grep -vE '^[A-Za-z0-9._/-]+@[0-9a-f]{40}$' | grep -q .; then bad 'a uses: is not pinned to a full SHA'; else ok 'every uses: is a full 40-hex SHA (no tags)'; fi
[[ $(yq -o json -I 0 '[.on | keys[]]' "$template") == '["pull_request","push"]' ]] && ok 'runs on pull_request and push' || bad 'triggers are not pull_request and push'
[[ $(yq '[.. | select(has("uses")) | select(.uses | test("upload-artifact")) | .with.name] | .[0]' "$template") == proven-coverage ]] && ok 'one artifact named proven-coverage' || bad 'artifact name is not proven-coverage'
[[ $(yq '[.. | select(has("uses")) | select(.uses | test("upload-artifact")) | .with."retention-days"] | .[0]' "$template") == 14 ]] && ok 'artifact retention is 14 days' || bad 'artifact retention is not 14 days'
grep -qE '(^|[^_a-z])exit 1' "$driver" && bad 'the driver can exit 1' || ok 'the driver has no exit 1'

# --- pin refusal, from the template's own fetch step
yq '.jobs.proven-coverage.steps[1].run' "$template" > "$tmp/fetch.sh"
rc=0; out=$(env -i PATH="$PATH" PROVEN_SHA=not-a-sha RUNNER_TEMP="$tmp/rt" GITHUB_ENV="$tmp/env" bash "$tmp/fetch.sh" 2>&1) || rc=$?
[[ $rc == 2 && $out == *PROVEN_COVERAGE_CLASS=not_run:pin* ]] && ok 'a malformed pin is NOT RUN before any fetch' || bad "malformed pin: exit $rc, output: $out"

# --- driver
export GITHUB_REPOSITORY=hyperpolymath/cov-fixture GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_RUN_ID=424242
unset GITHUB_STEP_SUMMARY
last() { tail -n 1 "$tmp/out"; }
mkws() { rm -rf -- "$tmp/ws"; mkdir -p "$tmp/ws/.github/workflows"; cp "$template" "$tmp/ws/.github/workflows/proven-coverage-collect.yml"; }
stamped=.github/workflows/proven-coverage-collect.yml

mkws
expect_rc 'a repo with none of the languages exits 0' 0 bash "$driver" collect "$tmp/ws" "$stamped"
[[ $(last) == PROVEN_COVERAGE_CLASS=nothing_to_collect ]] && grep -qi 'nothing to collect' "$tmp/ws/.proven-coverage/summary.md" && grep -qi 'nothing to collect' "$tmp/out" &&
  ok 'it says "nothing to collect"' || bad "no 'nothing to collect' summary: $(last)"
[[ $(jq '.languages | length' "$tmp/ws/.proven-coverage/collect-report.json") == 0 ]] && ok 'collect-report.json lists no language' || bad 'collect-report.json is wrong'
[[ $(bash "$driver" detect "$tmp/ws" | tr '\n' ' ') == 'rust=false elixir=false js=false ' ]] && ok 'detect finds nothing' || bad 'detect on an empty repo'

expect_rc 'a missing workspace is exit 2' 2 bash "$driver" collect "$tmp/absent"
env -u GITHUB_SHA bash "$driver" collect "$tmp/ws" "$stamped" >"$tmp/out" 2>&1 && rc=0 || rc=$?
[[ $rc == 2 && $(last) == PROVEN_COVERAGE_CLASS=not_run:env ]] && ok 'no GITHUB_SHA is NOT RUN, not an invented sidecar' || bad "no sha: $rc/$(last)"
sed -i 's/timeout-minutes: 30/timeout-minutes: 99/' "$tmp/ws/$stamped"
bash "$driver" collect "$tmp/ws" "$stamped" >"$tmp/out" 2>&1 && rc=0 || rc=$?
[[ $rc == 2 && $(last) == PROVEN_COVERAGE_CLASS=not_run:drift ]] && ok 'a drifted copy is NOT RUN (exit 2, never 1)' || bad "drift: $rc/$(last)"

# a tool that fails is reported, and the driver still exits 0
mkws; cp -R "$root/tests/fixtures/proven-coverage/rust/." "$tmp/ws/"
mkdir -p "$tmp/stub"
printf '#!/usr/bin/env bash\n[[ $1 == llvm-cov && $2 == --version ]] && { echo "cargo-llvm-cov 9.9.9"; exit 0; }\necho "stub cargo failing" >&2\nexit 101\n' > "$tmp/stub/cargo"
chmod +x "$tmp/stub/cargo"
rc=0; PATH="$tmp/stub:$PATH" bash "$driver" collect "$tmp/ws" "$stamped" >"$tmp/out" 2>&1 || rc=$?
[[ $rc == 0 && $(last) == PROVEN_COVERAGE_CLASS=collected ]] && ok 'a failing tool run still exits 0' || bad "failing tool: $rc/$(last)"
jq -e '.languages[0] | .language == "rust" and .status == "partial" and .raw == null and .proven == null and (.reason | test("exited 101"))' \
  "$tmp/ws/.proven-coverage/collect-report.json" >/dev/null && grep -q '| rust | no | no | ' "$tmp/ws/.proven-coverage/summary.md" && ok 'the missing reports and the reason are in the summary' || bad 'failing-tool summary'
[[ ! -e $tmp/ws/.proven-coverage/raw/llvm.json ]] && ok 'no report is left behind by a failed run' || bad 'a partial report was left behind'
rc=0; PATH="/usr/bin:/bin" bash "$driver" collect "$tmp/ws" "$stamped" >"$tmp/out" 2>&1 || rc=$?
[[ $rc == 0 ]] && grep -q 'cargo-llvm-cov is not installed' "$tmp/ws/.proven-coverage/summary.md" && ok 'an unmeasurable language is reported, not failed' || bad "no cargo: $rc"

# a consumer's own cov/ survives, and a stale Elixir export is never converted
mkws; mkdir -p "$tmp/ws/cov"; echo keep > "$tmp/ws/cov/keep.txt"
bash "$driver" collect "$tmp/ws" "$stamped" >"$tmp/out" 2>&1 || true
[[ $(cat "$tmp/ws/cov/keep.txt" 2>/dev/null) == keep && -d $tmp/ws/.proven-coverage ]] && ok "a consumer's cov/keep.txt survives a run" || bad "consumer cov/ was touched"
mkws; : > "$tmp/ws/mix.exs"; mkdir -p "$tmp/ws/cover"
echo stale > "$tmp/ws/cover/raw.coverdata"; echo stale > "$tmp/ws/cover/proven.coverdata"
cat > "$tmp/stub/mix" <<'STUB'
#!/usr/bin/env bash
echo "mix $*" >> "$STUB_LOG"
[[ $1 == run && ${*: -1} == --tools-version ]] && { echo 0.0.0; exit 0; }
[[ $1 == test ]] && exit 2
exit 0
STUB
chmod +x "$tmp/stub/mix"
rc=0; STUB_LOG="$tmp/mix.log" PATH="$tmp/stub:$PATH" bash "$driver" collect "$tmp/ws" "$stamped" >"$tmp/out" 2>&1 || rc=$?
[[ $rc == 0 && ! -e $tmp/ws/.proven-coverage/raw/elixir.lcov && ! -e $tmp/ws/.proven-coverage/proven/elixir.lcov ]] &&
  ! grep -q 'cover/' "$tmp/mix.log" && [[ ! -e $tmp/ws/cover/raw.coverdata ]] &&
  jq -e '.languages[0] | .raw == null and .proven == null and (.reason | test("no fresh coverdata"))' "$tmp/ws/.proven-coverage/collect-report.json" >/dev/null &&
  ok 'a stale coverdata file is deleted, not converted, when mix test fails' || { bad 'stale coverdata was converted or not reported'; cat "$tmp/mix.log"; }
rm -f "$tmp/stub/mix"

# --- real runs
sidecar_ok() { # REPORT ROLE TOOL
  local report=$1 role=$2 tool=$3
  jq -e --arg role "$role" --arg tool "$tool" --arg repo "$GITHUB_REPOSITORY" --arg sha "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" \
    '.schema == "hypatia.proven-coverage.report-meta/1" and .repo == $repo and .commit == $sha and .run_id == $run
     and .role == $role and .tool == $tool and (.tool_version | type == "string" and length > 0)' "$report.meta.json" >/dev/null
}
real() { # LANG FIXTURE TOOL_NAME REPORT_FILE -> runs the driver, leaves $tmp/ws
  local lang=$1 fixture=$2 tool=$3 file=$4
  mkws; cp -R "$root/tests/fixtures/proven-coverage/$fixture/." "$tmp/ws/"
  bash "$driver" collect "$tmp/ws" "$stamped" >"$tmp/out" 2>&1 || true
  [[ $(last) == PROVEN_COVERAGE_CLASS=collected ]] || { bad "$lang: driver did not finish collected: $(last)"; sed 's/^/    /' "$tmp/out" | tail -20; return 1; }
  local r
  for r in raw proven; do
    [[ -s $tmp/ws/.proven-coverage/$r/$file ]] || { bad "$lang: .proven-coverage/$r/$file missing; $(jq -r '.languages[0].reason' "$tmp/ws/.proven-coverage/collect-report.json")"; return 1; }
    sidecar_ok "$tmp/ws/.proven-coverage/$r/$file" "$r" "$tool" || { bad "$lang: $r sidecar invalid"; return 1; }
  done
  ok "$lang: raw and proven reports and sidecars exist and parse"
  grep -q "| $lang | yes | yes |" "$tmp/ws/.proven-coverage/summary.md" && ok "$lang: summary says both reports are present" || bad "$lang: summary row"
}
lcov_hits() { local f=$1; grep -E '^DA:' "$f" | awk -F'[:,]' '$3 > 0' | wc -l; }
lcov_ok() { # LANG REPORT_FILE: SF records, DA lines, LF/LH agree, no branch records, proven <= raw
  local lang=$1 file=$2 r f p q
  for r in raw proven; do
    f=$tmp/ws/.proven-coverage/$r/$file
    grep -q '^SF:' "$f" && grep -q '^DA:' "$f" && grep -q '^end_of_record' "$f" || { bad "$lang $r: not LCOV"; return; }
  done
  p=$(lcov_hits "$tmp/ws/.proven-coverage/proven/$file"); q=$(lcov_hits "$tmp/ws/.proven-coverage/raw/$file")
  [[ $p -le $q ]] && ok "$lang: proven hit lines <= raw hit lines ($p <= $q)" || bad "$lang: proven above raw"
  [[ $p -lt $q ]] && ok "$lang: the proven subset is strictly smaller here" || bad "$lang: proven run did not narrow"
}

PATH="$HOME/.cargo/bin:$PATH"
if command -v cargo >/dev/null && cargo llvm-cov --version >/dev/null 2>&1; then
  if real rust rust cargo-llvm-cov llvm.json; then
    for r in raw proven; do jq -e '.data[0].files | length > 0 and (.[0].summary.lines.count > 0)' "$tmp/ws/.proven-coverage/$r/llvm.json" >/dev/null || bad "rust $r llvm.json has no files"; done
    [[ $(jq '.data[0].totals.lines.covered' "$tmp/ws/.proven-coverage/proven/llvm.json") -lt $(jq '.data[0].totals.lines.covered' "$tmp/ws/.proven-coverage/raw/llvm.json") ]] &&
      ok 'rust: the prop_ run covers fewer lines than the raw run' || bad 'rust: proven run did not narrow'
    jq -e '.languages[0].status == "collected"' "$tmp/ws/.proven-coverage/collect-report.json" >/dev/null && ok 'rust: collect-report.json says collected' || bad 'rust: collect-report'
  fi
else skip 'rust: cargo-llvm-cov is not installed'; fi

for d in /opt/ex117/bin /opt/otp27/bin; do [[ -d $d ]] && PATH="$d:$PATH"; done
export ELIXIR_ERL_OPTIONS=${ELIXIR_ERL_OPTIONS:-+fnu}
if command -v mix >/dev/null && command -v erl >/dev/null; then
  if real elixir mix erlang-cover elixir.lcov; then
    lcov_ok elixir elixir.lcov
    grep -qE '^(BRDA|BRF|BRH):' "$tmp/ws/.proven-coverage/raw/elixir.lcov" && bad 'elixir: the converter wrote branch records' || ok 'elixir: lines only (no BRDA/BRF/BRH)'
    grep -qx 'SF:lib/cov_demo.ex' "$tmp/ws/.proven-coverage/raw/elixir.lcov" && ok 'elixir: source paths are repo-relative' || bad 'elixir: source path is not repo-relative'
  fi
else skip 'elixir: mix or erl is not installed'; fi

[[ -d /opt/node22/bin ]] && PATH="/opt/node22/bin:$PATH"
if command -v node >/dev/null && command -v npx >/dev/null; then
  if real js js c8 js.lcov; then
    lcov_ok js js.lcov
    [[ $(jq -r .tool_version "$tmp/ws/.proven-coverage/raw/js.lcov.meta.json") == 10.1.3 ]] && ok 'js: c8 10.1.3 is the recorded tool version' || bad 'js: c8 version'
  fi
else skip 'js: node or npx is not installed'; fi

[[ $fail == 0 ]] || { echo "proven-coverage-collect: FAIL" >&2; exit 1; }
echo "proven-coverage-collect: ok"
