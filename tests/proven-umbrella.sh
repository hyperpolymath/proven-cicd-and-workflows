#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Controls for the umbrella gate's scripts: detect, run, bench, integrity.
# Every assertion has a green and a red side, so a script that always says
# "ok" is refused.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
GATE=$(bash "$ROOT/scripts/proven-gate-bin.sh") || { echo "cannot build proven-gate"; exit 2; }
detect() { "$GATE" detect "$@"; }
expect() { # name expected-rc got-rc
  local name=$1 want=$2 got=$3
  [[ $want == "$got" ]] && ok "$name" || bad "$name (want rc $want, got $got)"
}
mk() { rm -rf "$W/r"; mkdir -p "$W/r"; ( cd "$W/r" && git init -q . ); }

echo "detect:"
mk; detect "$W/r" >/dev/null 2>&1; expect "missing manifest fails" 1 $?
mk; printf 'schema = "wrong"\n' > "$W/r/.proven.toml"; detect "$W/r" >/dev/null 2>&1; expect "wrong schema fails" 1 $?
mk; printf 'schema = [' > "$W/r/.proven.toml"; detect "$W/r" >/dev/null 2>&1; expect "unparseable manifest fails" 1 $?
mk; printf 'schema = "proven/manifest/v1"\n' > "$W/r/.proven.toml"; detect "$W/r" >/dev/null 2>&1; expect "language-free repo with manifest is ok" 0 $?
mk; printf 'schema = "proven/manifest/v1"\n' > "$W/r/.proven.toml"; : > "$W/r/Cargo.toml"
out=$(detect "$W/r" 2>&1); expect "rust repo plans defaults" 0 $?
[[ $(jq '.jobs|length' <<<"$out") == 4 ]] && ok "rust plans 4 category jobs" || bad "rust job count"
mk; printf 'schema = "proven/manifest/v1"\n' > "$W/r/.proven.toml"; : > "$W/r/main.c"
out=$(detect "$W/r" 2>&1); expect "unknown language (c) with no runner fails" 1 $?
grep -q missing-runner <<<"$out" && ok "c is named missing-runner" || bad "missing-runner not reported"
mk; printf 'schema = "proven/manifest/v1"\n[languages.ignore.c]\nreason = "vendored header only"\n' > "$W/r/.proven.toml"; : > "$W/r/main.c"
detect "$W/r" >/dev/null 2>&1; expect "language ignore with reason passes" 0 $?
mk; printf 'schema = "proven/manifest/v1"\n[languages.ignore.c]\nreason = " "\n' > "$W/r/.proven.toml"; : > "$W/r/main.c"
detect "$W/r" >/dev/null 2>&1; expect "language ignore with blank reason fails" 1 $?
mk; printf 'schema = "proven/manifest/v1"\n[categories.smoke]\nna = ""\n' > "$W/r/.proven.toml"; : > "$W/r/Cargo.toml"
detect "$W/r" >/dev/null 2>&1; expect "N/A with empty reason fails" 1 $?
mk; printf 'schema = "proven/manifest/v1"\n[categories.p2p]\nna = "single binary, no seam"\n[categories.smoke]\nna = "x"\n' > "$W/r/.proven.toml"; : > "$W/r/Cargo.toml"
out=$(detect "$W/r" 2>&1); [[ $(jq '.jobs|length' <<<"$out") == 2 && $(jq '.na|length' <<<"$out") == 2 ]] && ok "N/A with reason removes the job and is recorded" || bad "N/A handling"
mk; printf 'schema = "proven/manifest/v1"\n[categories.smoke.waiver]\nreason = "adopting"\nuntil = "2026-12-31"\n' > "$W/r/.proven.toml"; : > "$W/r/Cargo.toml"
detect "$W/r" --today 2026-11-26 >/dev/null 2>&1; expect "unexpired waiver passes" 0 $?
detect "$W/r" --today 2027-01-01 >/dev/null 2>&1; expect "expired waiver fails" 1 $?
mk; printf 'schema = "proven/manifest/v1"\n[languages]\ndeclare = ["c"]\n' > "$W/r/.proven.toml"
detect "$W/r" >/dev/null 2>&1; expect "declared language with no runner fails" 1 $?
mk; printf 'schema = "proven/manifest/v1"\n' > "$W/r/.proven.toml"; mkdir -p "$W/r/a" "$W/r/b"; : > "$W/r/a/go.mod"; : > "$W/r/b/go.mod"
out=$(detect "$W/r" 2>&1); [[ $(jq '[.jobs[]|select(.category=="build")]|length' <<<"$out") == 2 && $(jq '[.jobs[].id]|unique|length' <<<"$out") == $(jq '.jobs|length' <<<"$out") ]] && ok "two Go roots plan two build jobs with unique ids" || bad "multi-root go"
mk; printf 'schema = "proven/manifest/v1"\n' > "$W/r/.proven.toml"; mkdir -p "$W/r/apps/api" "$W/r/tests"; : > "$W/r/apps/api/Cargo.toml"; printf 'true\n' > "$W/r/tests/build.sh"
out=$(detect "$W/r" 2>&1); [[ $(jq -r '.jobs[]|select(.id=="build-rust")|.dir' <<<"$out") == . ]] && ok "convention command runs from the repo root" || bad "convention dir"
mk; printf 'schema = "proven/manifest/v1"\n[categories.chaos]\nna = "x"\n' > "$W/r/.proven.toml"
detect "$W/r" >/dev/null 2>&1; expect "unknown category fails" 1 $?
mk; printf 'schema = "proven/manifest/v1"\n' > "$W/r/.proven.toml"; : > "$W/r/Cargo.toml"; printf 'smoke:\n\techo hi\n' > "$W/r/justfile"
out=$(detect "$W/r" 2>&1); [[ $(jq -r '.jobs[]|select(.category=="smoke")|.command' <<<"$out") == "just smoke" ]] && ok "justfile recipe beats language default" || bad "justfile precedence"

echo "run (zero tests is not a pass):"
mkdir -p "$W/d"
bash "$ROOT/scripts/proven-run.sh" unit rust "$W/d" 'echo "running 0 tests"' >/dev/null 2>&1; expect "rust zero tests fails" 1 $?
bash "$ROOT/scripts/proven-run.sh" unit rust "$W/d" 'echo "running 3 tests"' >/dev/null 2>&1; expect "rust 3 tests passes" 0 $?
bash "$ROOT/scripts/proven-run.sh" unit rust "$W/d" 'echo "running 3 tests"; exit 7' >/dev/null 2>&1; expect "non-zero exit fails" 1 $?
bash "$ROOT/scripts/proven-run.sh" build rust "$W/d" 'true' >/dev/null 2>&1; expect "build need not run tests" 0 $?
bash "$ROOT/scripts/proven-run.sh" unit shell "$W/nope" 'true' >/dev/null 2>&1; expect "missing dir cannot run" 2 $?

echo "bench (Six Sigma):"
g() { "$GATE" bench-gate "$@" >/dev/null 2>&1; }
g 100 --history 100,100; expect "equal is Ordinary" 0 $?
g 119 --history 100;     expect "19% worse is Ordinary" 0 $?
g 130 --history 100;     expect "30% worse is Acceptable (needs reviewer)" 3 $?
g 151 --history 100;     expect "51% worse is Unacceptable" 1 $?
g 70  --history 100;     expect "30% better is Extraordinary, passes" 0 $?
g 60 --history 100 --higher-is-better; expect "higher-is-better: 40% lower is Acceptable" 3 $?
g 100;                   expect "no history and no baselining fails" 2 $?
g nan --history 100;     expect "nan current fails" 2 $?
g 100 --history nan,100; expect "nan history fails" 2 $?
g 5 --history=-10;       expect "negative baseline is no baseline" 2 $?
g 1.2 --history 1.0;     expect "exactly 20% worse (float noise) is Acceptable" 3 $?
g 100 --baselining;      expect "no history with baselining passes" 0 $?
g 130 --history 1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,100,100,100,100,100,100,100,100,100,100; expect "only the last 10 history values count" 3 $?

echo "integrity (ER-A8):"
mkint() { mk; mkdir -p "$W/r/.github/workflows"; cp "$ROOT/.github/workflows/proven-lock-gate.yml" "$W/r/.github/workflows/"; cp "$ROOT/templates/proven-caller.yml" "$W/r/.github/workflows/proven.yml"; sed -i 's/__PROVEN_SHA__/0123456789abcdef0123456789abcdef01234567/;s/__PROVEN_TAG__/v0/' "$W/r/.github/workflows/proven.yml"; }
integ() { PROVEN_ROOT="$W/r" "$GATE" integrity .github/workflows/proven.yml >/dev/null 2>&1; }
mkint; integ; expect "template caller is consistent" 0 $?
mkint; printf 'on: [' > "$W/r/.github/workflows/broken.yml"; integ; expect "an unparseable workflow fails" 1 $?
mkint; rm "$W/r/.github/workflows/proven-lock-gate.yml"; integ; expect "missing stamped lock gate fails" 1 $?
mkint; sed -i 's|^    uses:|    if: false\n    uses:|' "$W/r/.github/workflows/proven.yml"; integ; expect "an if: on the caller job fails" 1 $?
mkint; sed -i 's|^  pull_request:|  pull_request:\n    paths: [src/**]|' "$W/r/.github/workflows/proven.yml"; integ; expect "a pull_request paths filter fails" 1 $?
mkint; printf 'name: x\non: push\njobs:\n  a:\n    runs-on: x\n    continue-on-error: "true"\n    steps: []\n' > "$W/r/.github/workflows/proven-extra.yaml"; integ; expect "quoted continue-on-error in proven*.yaml fails" 1 $?
mkint; sed -i 's|^  proven:|  other:|' "$W/r/.github/workflows/proven.yml"; integ; expect "a renamed caller job id fails" 1 $?
mkint; sed -i 's|^  pull_request:||;s|^  merge_group:||' "$W/r/.github/workflows/proven.yml"; integ; expect "no pull_request trigger fails" 1 $?
mkint; rm "$W/r/.github/workflows/proven.yml"; integ; expect "missing caller fails" 1 $?

echo "proven-umbrella: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
