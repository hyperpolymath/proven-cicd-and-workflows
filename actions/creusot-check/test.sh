#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the Creusot gate must fail for each thing it claims to check,
# under the exact composite shell (bash --noprofile --norc -e -o pipefail).
#
# The prove phase is exercised against a stand-in `cargo-creusot` on PATH. The
# stub says "unproved" for any crate whose lib.rs contains the planted
# failing marker or a `// UNPROVED` line, and "proved" otherwise — which is
# the contract the real tool must honour (exit code and nonzero proved-file
# denominator are the oracle).
# A second stub that can only say yes must make the gate refuse (exit 2).
# This does NOT prove Why3/SMT integration; the planted controls in check.sh
# do that at runtime, against the real tool, on every run.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$here/check.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
command -v cargo >/dev/null || { echo "cargo is required (it dispatches 'cargo creusot' to cargo-creusot on PATH)"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"
FIX="$WORK/fixture"
ln -s "$here/source-facts" "$WORK/source-facts"

echo "== the pinned source reader compiles and its syntax controls pass =="
if ! cargo test --locked --manifest-path "$here/source-facts/Cargo.toml" --target-dir "$WORK/facts/source-target" \
  || ! cargo fmt --manifest-path "$here/source-facts/Cargo.toml" --check \
  || ! cargo clippy --locked --manifest-path "$here/source-facts/Cargo.toml" --target-dir "$WORK/facts/source-target" --all-targets -- -D warnings; then
  echo "source reader validation failed" >&2
  exit 1
fi

echo "== the reader manifest is standalone inside a caller Cargo workspace =="
# The gate is checked out under the caller's tree (.cicd-suite/). If the caller
# is itself a Cargo workspace, a reader manifest without its own [workspace]
# table is rejected by cargo ("believes it's in a workspace when it's not").
CALLER="$WORK/caller-workspace"
rm -rf "$CALLER"; mkdir -p "$CALLER/member/src" "$CALLER/.cicd-suite/actions"
git -C "$CALLER" init -q
printf '[workspace]\nmembers = ["member"]\nresolver = "2"\n' > "$CALLER/Cargo.toml"
printf '[package]\nname = "member"\nversion = "0.1.0"\nedition = "2021"\n' > "$CALLER/member/Cargo.toml"
printf 'pub fn f() {}\n' > "$CALLER/member/src/lib.rs"
cp -a "$here" "$CALLER/.cicd-suite/actions/creusot-check"
rm -rf "$CALLER/.cicd-suite/actions/creusot-check/source-facts/target"
nested_reader="$CALLER/.cicd-suite/actions/creusot-check/source-facts/Cargo.toml"
if cargo metadata --locked --format-version 1 --no-deps --manifest-path "$nested_reader" > "$WORK/nested-metadata.json" 2> "$WORK/nested-metadata.err"; then
  ok "cargo metadata on the reader succeeds inside a caller workspace (no exclude)"
else
  bad "cargo metadata on the nested reader failed: $(cat "$WORK/nested-metadata.err")"
fi
git -C "$CALLER" add -A >/dev/null && git -C "$CALLER" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -qm caller >/dev/null
if ( cd "$CALLER" && env CREUSOT_GATE_PHASE=detect CREUSOT_FACTS="$WORK/nested-facts" \
      bash --noprofile --norc -e -o pipefail "$CALLER/.cicd-suite/actions/creusot-check/check.sh" ) > "$OUT" 2>&1; then
  ok "the gate builds its reader from a checkout nested in a caller workspace"
else
  bad "gate from a nested checkout failed: $(cat "$OUT")"
fi
rm -rf "$CALLER"

fresh_fixture() {
    rm -rf "$FIX"; mkdir -p "$FIX/src" "$FIX/docs"
    git -C "$FIX" init -q
    git -C "$FIX" config user.email t@example.invalid
    git -C "$FIX" config user.name t
    # These temporary fixture commits are not published. A developer's locked
    # signing key must not turn fixture creation into missing source evidence.
    git -C "$FIX" config commit.gpgsign false
    printf '[package]\nname = "fx"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n' > "$FIX/Cargo.toml"
    printf '//! fixture\npub fn id(x: u32) -> u32 { x }\n' > "$FIX/src/lib.rs"
    printf '= fx\n\nA small crate.\n' > "$FIX/README.adoc"
    printf '{"packages":["creusot"],"provers":["z3"]}\n' > "$FIX/why3find.json"
    git -C "$FIX" add -A && git -C "$FIX" commit -qm fixture || exit 2
}
commit() { git -C "$FIX" add -A && git -C "$FIX" commit -qm change >/dev/null || exit 2; }
run_phase() { # <phase> [env...]
    local phase="$1"; shift
    : > "$WORK/receipt"
    ( cd "$FIX" && env CREUSOT_GATE_PHASE="$phase" CREUSOT_FACTS="$WORK/facts" \
        GITHUB_OUTPUT="$WORK/receipt" CREUSOT_SUITE_REVISION=1111111111111111111111111111111111111111 "$@" \
        bash --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1
    RC=$?
}

echo "== a plain crate: no obligations, no claims, silent =="
fresh_fixture
run_phase detect
[[ "$RC" -eq 0 ]] && ok "detect exits 0" || { bad "detect exits $RC"; cat "$OUT"; }
grep -qx 'obligations=false' "$OUT" && ok "obligations=false" || bad "obligations misreported: $(cat "$OUT")"
grep -qx 'claims=false' "$OUT" && ok "claims=false" || bad "claims misreported"
run_phase theatre
[[ "$RC" -eq 0 ]] && ok "theatre exits 0" || bad "theatre exits $RC"
grep -q 'nothing claims to be' "$OUT" && ok "says it is silent, not green-as-assurance" || bad "no silence notice"
run_phase prove
[[ "$RC" -eq 2 ]] && ok "prove on a crate without obligations is exit 2 (no proof performed)" || bad "prove exits $RC, expected 2"

echo "== T1: a README claim with nothing behind it is a hard failure =="
printf '= fx\n\nThis crate is verified with Creusot.\n' > "$FIX/README.adoc"; commit
run_phase detect
grep -qx 'claims=true' "$OUT" && ok "detect sees the claim" || bad "claim not seen: $(cat "$OUT")"
run_phase theatre
[[ "$RC" -eq 1 ]] && ok "theatre exits 1" || bad "theatre exits $RC, expected 1"
grep -q '::error file=README.adoc,line=3::T1 Creusot theatre' "$OUT" && ok "annotates the claim at its line" || bad "T1 annotation missing: $(cat "$OUT")"

echo "== a roadmap sentence is not a claim =="
printf '= fx\n\nIt is planned to have this crate verified with Creusot.\n' > "$FIX/README.adoc"; commit
run_phase theatre
[[ "$RC" -eq 0 ]] && ok "planned work does not fire T1" || bad "a plan fired T1 (exit $RC)"

echo "== T2: a Creusot dependency with no contracts is hollow =="
printf '= fx\n\nA small crate.\n' > "$FIX/README.adoc"
printf '[package]\nname = "fx"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\ncreusot-std = "0.14"\n' > "$FIX/Cargo.toml"; commit
run_phase detect
grep -qx 'obligations=true' "$OUT" && ok "the dependency counts as an obligation" || bad "dependency not seen"
grep -qx 'creusot_version=0.14' "$OUT" && ok "reads the creusot-std version" || bad "version not read: $(cat "$OUT")"
run_phase theatre
[[ "$RC" -eq 0 ]] && ok "hollow is a warning by default" || bad "hollow failed by default (exit $RC)"
grep -q '::warning::T2 hollow' "$OUT" && ok "and is named" || bad "T2 warning missing"
run_phase theatre ENFORCE_HOLLOW=true
[[ "$RC" -eq 1 ]] && ok "hollow is a failure with ENFORCE_HOLLOW=true" || bad "ENFORCE_HOLLOW did not fail (exit $RC)"

echo "== comments, literals and unexpanded tokens cannot make a hollow crate pass =="
cat > "$FIX/src/lib.rs" <<'RS'
/* nested /* #[ensures(false)] */ #[trusted] */
// #[requires(false)]
/// Example only: `#[trusted]`.
pub fn text() { let _ = r###"#[ensures(false)]"###; let _ = "#[trusted]"; }
macro_rules! quoted { () => { #[ensures(false)] fn not_expanded() {} }; }
RS
commit
run_phase detect
[[ "$RC" -eq 0 ]] && grep -qx 'contract_count=0' "$OUT" && grep -qx 'trusted_count=0' "$OUT" \
  && ok "comment, string and macro token lookalikes are not declarations" || { bad "source lookalikes were credited"; cat "$OUT"; }
run_phase theatre ENFORCE_HOLLOW=true
[[ "$RC" -eq 1 ]] && ok "lookalikes cannot defeat the enforcing hollow gate" || bad "lookalikes exit $RC"

echo "== conditional qualified contracts are bound to active functions =="
cat > "$FIX/src/lib.rs" <<'RS'
#[cfg_attr(creusot, creusot_std::macros::ensures(
    result == x
))]
pub fn id(x: u32) -> u32 { x }
#[cfg_attr(creusot, creusot_std::macros::trusted)]
pub fn oracle() -> u32 { 7 }
#[cfg(not(creusot))]
mod native { #[ensures(false)] fn inactive() {} }
#[cfg(test)] #[trusted] fn test_only() {}
RS
commit
run_phase detect
[[ "$RC" -eq 0 ]] && grep -qx 'contract_count=1' "$OUT" && grep -qx 'trusted_count=1' "$OUT" \
  && ok "multiline conditional contract and trusted function are counted exactly" || { bad "conditional facts wrong"; cat "$OUT"; }
run_phase theatre ENFORCE_HOLLOW=true
[[ "$RC" -eq 0 ]] && grep -q 'trusted: src/lib.rs:5' "$OUT" \
  && ok "conditional contract satisfies admission and residue reports the declaration line" || { bad "conditional theatre exits $RC"; cat "$OUT"; }

echo "== unsupported or malformed declarations cannot provide partial evidence =="
for source in '#[cfg_attr(feature = "proof", ensures(true))] fn f() {}' '#[ensures(true)] struct NotAFunction;' '#[ensures(true)] fn broken('; do
  printf '%s\n' "$source" > "$FIX/src/lib.rs"; commit
  run_phase detect
  if [[ "$RC" -eq 2 ]] && ! grep -q '^contract_count=' "$OUT"; then
    ok "unresolved, unbound or malformed source is unavailable: $source"
  else
    bad "unsupported source produced facts (exit $RC): $source"; cat "$OUT"
  fi
done

echo "== contracts present: T2 silent, T3 lists trusted =="
cat > "$FIX/src/lib.rs" <<'RS'
//! fixture
use creusot_std::prelude::*;
#[ensures(result == x)]
pub fn id(x: u32) -> u32 { x }
#[trusted]
pub fn oracle() -> u32 { 7 }
RS
commit
run_phase detect
grep -qx 'contract_count=1' "$OUT" && ok "counts one contract" || bad "contract count wrong: $(cat "$OUT")"
grep -qx 'trusted_count=1' "$OUT" && ok "counts one trusted" || bad "trusted count wrong"
run_phase theatre ENFORCE_HOLLOW=true
[[ "$RC" -eq 0 ]] && ok "theatre exits 0 with a real contract" || bad "theatre exits $RC"
grep -q 'T3 residue: 1 #\[trusted\]' "$OUT" && ok "the trusted residue is listed" || bad "residue not listed"

echo "== prove: stub oracle that CAN say no =="
STAND_IN="$WORK/bin"; mkdir -p "$STAND_IN"
cat > "$STAND_IN/cargo-creusot" <<'SH'
#!/usr/bin/env bash
# v0.14 compiles/proves without a subcommand. A CLI parse error must not
# be mistaken for a rejected proof: reject the obsolete invocation here.
[[ "${1:-}" = "creusot" ]] || exit 64  # cargo supplies the plugin name
[[ "${2:-}" != "--help" ]] || exit 0
if [[ "${2:-}" = "prove" ]]; then
  echo "obsolete prove subcommand" >&2; exit 64
fi
if [[ "${2:-}" = "init" ]]; then
  # Stand-in only: real init copies the installed tool's configured template.
  printf '{"stand_in":true}\n' > why3find.json
  exit 0
fi
if [[ -f Cargo.toml ]] && grep -q 'name = "creusot-control-' Cargo.toml && [[ ! -s why3find.json ]]; then
  echo "missing control Why3find configuration" >&2; exit 65
fi
if ! grep -q 'name = "creusot-control-' Cargo.toml; then
  package="$(sed -nE 's/^name = "([^"]+)"/\1/p' Cargo.toml)"
  if [[ "${2:-}" != -p ]] || [[ "${3:-}" != "$package" ]]; then
    echo "caller package was not selected explicitly" >&2; exit 66
  fi
  echo "stub: selected package $package"
fi
if grep -qE 'planted_must_fail|// UNPROVED' src/lib.rs 2>/dev/null; then
  echo "stub: 1 goal unproved"; exit 1
fi
echo "Proved (1 files) [stand-in oracle]"; exit 0
SH
chmod +x "$STAND_IN/cargo-creusot"
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 0 ]] && ok "prove exits 0 when every crate proves" || { bad "prove exits $RC"; cat "$OUT"; }
for fact in execution_stage=substantive execution_outcome=passed controls_passed=true proof_started=true proof_completed=true crates_expected=1 crates_attempted=1 crates_completed=1 proof_exit_code=0; do
  grep -qx "$fact" "$WORK/receipt" && ok "execution receipt: $fact" || bad "missing execution fact: $fact"
done
grep -qx "source_revision=$(git -C "$FIX" rev-parse HEAD)" "$WORK/receipt" && ok "records actual checked-out revision" || bad "wrong receipt revision"
grep -q 'false contract refused' "$OUT" && ok "planted failing control was exercised" || bad "failing control not run"
grep -q 'true contract proved' "$OUT" && ok "planted passing control was exercised" || bad "passing control not run"
echo "== exit zero without a proved-file denominator is not proof evidence =="
cp "$STAND_IN/cargo-creusot" "$WORK/denominator-oracle"
sed 's@Proved (1 files) \[stand-in oracle\]@Proved (verif/creusot_control_passing_rlib/planted_must_pass.coma) ✔@' \
  "$WORK/denominator-oracle" > "$STAND_IN/cargo-creusot"
run_phase prove PATH="$STAND_IN:$PATH"
if [[ "$RC" -eq 0 ]] && grep -qx 'controls_passed=true' "$WORK/receipt" && grep -qx 'execution_outcome=passed' "$WORK/receipt"; then
  ok "real Why3find singleton format accepted for control and caller"
else
  bad "singleton proof report refused (exit $RC)"; cat "$OUT"
fi
for output in 'Proved (0 files)' 'completed without a proof report' 'Proved () ✔' 'Proved (unrelated.txt) ✔' 'Proved (verif/missing.coma)' 'Proved (verif/failed.coma) ✘'; do
  sed "s@Proved (1 files) \[stand-in oracle\]@$output@" "$WORK/denominator-oracle" > "$STAND_IN/cargo-creusot"
  run_phase prove PATH="$STAND_IN:$PATH"
  if [[ "$RC" -eq 2 ]] && grep -qx 'execution_stage=harness' "$WORK/receipt" && grep -qx 'proof_started=false' "$WORK/receipt"; then
    ok "positive control without work refuses caller execution: $output"
  else
    bad "empty positive control was credited (exit $RC)"; cat "$OUT"
  fi
done
awk '/echo "Proved \(1 files\)/ { print "if ! grep -q '\''name = \"creusot-control-'\'' Cargo.toml; then echo '\''Proved (0 files)'\''; exit 0; fi" } { print }' \
  "$WORK/denominator-oracle" > "$STAND_IN/cargo-creusot"
run_phase prove PATH="$STAND_IN:$PATH"
if [[ "$RC" -eq 2 ]] && grep -qx 'execution_stage=substantive' "$WORK/receipt" && grep -qx 'execution_outcome=unavailable' "$WORK/receipt" \
  && grep -qx 'proof_completed=true' "$WORK/receipt"; then
  ok "completed caller command with zero proof work stays unavailable"
else
  bad "empty caller proof was credited (exit $RC)"; cat "$OUT"
fi
cp "$WORK/denominator-oracle" "$STAND_IN/cargo-creusot"
echo "== caller proof scope cannot be overridden with extra arguments =="
run_phase prove PATH="$STAND_IN:$PATH" PROVE_ARGS='--no-cache --why3session -j 2'
[[ "$RC" -eq 0 ]] && ok "supported operational options preserve caller execution" || { bad "supported options exit $RC"; cat "$OUT"; }
run_phase prove PATH="$STAND_IN:$PATH" PROVE_ARGS='-j2'
[[ "$RC" -eq 0 ]] && ok "compact positive prover concurrency is normalised safely" || bad "compact concurrency exits $RC"
for unsafe in '--only coma' '--only=prove' '--dry-run-why3find' '--package fx' '-pfx' '--workspace' '--manifest-path elsewhere/Cargo.toml' '-- --no-default-features' '--why3find-arg=--help' 'planted_*' '--replay' '--no-check-version' '--creusot-rustc=/tmp/fake' 'doc' '-j' '-j 0' '-j=-1' $'--no-cache\n--only coma'; do
  run_phase prove PATH="$STAND_IN:$PATH" PROVE_ARGS="$unsafe"
  if [[ "$RC" -eq 2 ]] && grep -qx 'execution_stage=setup' "$WORK/receipt" && grep -qx 'proof_started=false' "$WORK/receipt"; then
    ok "scope-changing or malformed arguments refused before execution: $unsafe"
  else
    bad "unsafe arguments accepted or misattributed: $unsafe (exit $RC)"
    cat "$OUT"
  fi
done
echo "== obsolete CLI mutation must not produce a proof verdict =="
original_checker="$checker"
sed 's/cargo creusot "${prove_options\[@\]}"/cargo creusot prove "${prove_options[@]}"/g' "$checker" > "$WORK/obsolete-check.sh"
checker="$WORK/obsolete-check.sh"
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 2 ]] && ok "obsolete subcommand is NOT RUN, never proof success" || bad "obsolete CLI exited $RC"
grep -q 'obsolete prove subcommand' "$OUT" && ok "strict v0.14 oracle rejected the obsolete CLI" || bad "CLI mutant was not exercised"
checker="$original_checker"
echo "== control initialisation must supply configuration =="
sed '/printf.*stand_in.*why3find.json/d' "$STAND_IN/cargo-creusot" > "$WORK/no-config-oracle"
cp "$STAND_IN/cargo-creusot" "$WORK/good-oracle"
cp "$WORK/no-config-oracle" "$STAND_IN/cargo-creusot"
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 2 ]] && ok "missing control configuration is NOT RUN" || bad "missing configuration exited $RC"
grep -q 'control initialisation did not supply why3find.json' "$OUT" && ok "names the actual setup failure" || bad "configuration failure not explained"
cp "$WORK/good-oracle" "$STAND_IN/cargo-creusot"
echo "== caller prerequisites must be distinguished from a failed proof =="
mv "$FIX/why3find.json" "$WORK/caller-config"
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 2 ]] && ok "missing caller configuration is NOT RUN" || bad "missing caller configuration exited $RC"
grep -qx 'execution_stage=setup' "$WORK/receipt" && grep -qx 'proof_started=false' "$WORK/receipt" && ok "configuration failure is setup, not a caller proof result" || bad "wrong configuration failure attribution"
mv "$WORK/caller-config" "$FIX/why3find.json"
cp "$FIX/Cargo.toml" "$WORK/caller-manifest"
sed -i '/^creusot-std = /d' "$FIX/Cargo.toml"
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 2 ]] && ok "attributes with zero selected crates cannot pass" || bad "zero crate commands exited $RC"
grep -qx 'crates_attempted=0' "$WORK/receipt" && ok "zero commands recorded honestly" || bad "invented a caller command"
mv "$WORK/caller-manifest" "$FIX/Cargo.toml"
echo "== Cargo workspace configuration and package scope use real metadata =="
cp -a "$FIX" "$WORK/single-package"
mkdir -p "$FIX/member"
mv "$FIX/src" "$FIX/member/src"
cat > "$FIX/Cargo.toml" <<'TOML'
[workspace]
members = ["member"]
resolver = "2"
[workspace.dependencies]
creusot-std = "0.14"
TOML
cat > "$FIX/member/Cargo.toml" <<'TOML'
[package]
name = "fx-member"
version = "0.1.0"
edition = "2021"
[dependencies]
creusot-std = { workspace = true }
TOML
commit
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 0 ]] && ok "workspace root configuration serves a real member package" || { bad "workspace root configuration exits $RC"; cat "$OUT"; }
grep -qx 'crates_expected=1' "$WORK/receipt" && ok "virtual workspace is not counted as a second proof package" || bad "virtual workspace was counted"
grep -q 'stub: selected package fx-member' "$OUT" && ok "caller command selects the discovered Cargo package explicitly" || bad "caller package selection missing"
run_phase prove PATH="$STAND_IN:$PATH" WORKING_DIRECTORY=member
[[ "$RC" -eq 0 ]] && ok "member working directory uses the same repository workspace root" || { bad "member working directory exits $RC"; cat "$OUT"; }
mv "$FIX/why3find.json" "$FIX/member/why3find.json"
run_phase prove PATH="$STAND_IN:$PATH" WORKING_DIRECTORY=member
[[ "$RC" -eq 2 ]] && ok "member-local configuration cannot substitute for the workspace configuration" || bad "member-only configuration exits $RC"
grep -qx 'proof_started=false' "$WORK/receipt" && ok "workspace configuration failure precedes caller execution" || bad "workspace configuration failure started a caller command"
mv "$FIX/member/why3find.json" "$WORK/ambient-why3find.json"
ln -s "$WORK/ambient-why3find.json" "$FIX/why3find.json"
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 2 ]] && ok "configuration symlink outside the source repository is refused" || bad "ambient configuration exits $RC"
rm "$FIX/why3find.json"
mv "$WORK/ambient-why3find.json" "$FIX/why3find.json"
printf 'not JSON\n' > "$FIX/why3find.json"
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 2 ]] && ok "malformed workspace configuration is a prerequisite failure" || bad "malformed configuration exits $RC"
printf '{"packages":["creusot"],"provers":["z3"]}\n' > "$FIX/why3find.json"
printf '\n[invalid TOML\n' >> "$FIX/member/Cargo.toml"
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 2 ]] && ok "unresolvable Cargo metadata cannot become a proof result" || bad "invalid Cargo metadata exits $RC"
rm -rf "$FIX"
cp -a "$WORK/single-package" "$FIX"
# A valid Cargo workspace may itself live above the Git repository. The gate
# must refuse its config rather than accept ambient state outside the subject.
printf '[workspace]\nmembers = ["fixture"]\n' > "$WORK/Cargo.toml"
sed -i '/^edition = /a workspace = ".."' "$FIX/Cargo.toml"
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 2 ]] && ok "a Cargo workspace outside the subject repository is refused" || bad "external Cargo workspace exits $RC"
grep -q 'Cargo workspace is outside the source repository' "$OUT" && ok "external workspace boundary failure is explicit" || { bad "workspace boundary failure not explained"; cat "$OUT"; }
rm "$WORK/Cargo.toml"
rm -rf "$FIX"
mv "$WORK/single-package" "$FIX"
printf '// UNPROVED\n' >> "$FIX/src/lib.rs"; commit
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 1 ]] && ok "an unproved crate fails the gate" || bad "unproved crate exits $RC, expected 1"
grep -qx 'execution_stage=substantive' "$WORK/receipt" && grep -qx 'execution_outcome=failed' "$WORK/receipt" && grep -qx 'proof_completed=true' "$WORK/receipt" && ok "a completed failing invocation is distinguished from a prerequisite" || bad "wrong caller failure attribution"
grep -q "::error file=./Cargo.toml::creusot-check\[prove\]" "$OUT" && ok "the failing crate is annotated" || bad "crate not annotated: $(cat "$OUT")"

echo "== detect: every spelling of the dependency selects its package; lookalikes select nothing =="
cp -a "$FIX" "$WORK/pre-detect-forms"
detect_manifest() { # <label> <expect: select|none> <manifest body after the [package] header>
    local label="$1" expect="$2"
    printf '[package]\nname = "fx"\nversion = "0.1.0"\nedition = "2021"\n%s\n' "$3" > "$FIX/Cargo.toml"
    [[ -z "${4:-}" ]] || sed -i 's/$/\r/' "$FIX/Cargo.toml"   # 4th argument: CRLF line endings
    commit
    run_phase detect
    local selected; selected="$(cat "$WORK/facts/crates")"
    if [[ "$expect" = select ]]; then
      [[ "$RC" -eq 0 && "$selected" = "." ]] && grep -qx 'obligations=true' "$OUT" \
        && ok "selects: $label" || { bad "not selected: $label (exit $RC, crates='$selected')"; cat "$OUT"; }
    else
      [[ "$RC" -eq 0 && -z "$selected" ]] && grep -qx 'obligations=false' "$OUT" \
        && ok "selects nothing: $label" || { bad "wrongly selected: $label (exit $RC, crates='$selected')"; cat "$OUT"; }
    fi
}
fresh_fixture
detect_manifest 'inline value'                       select '[dependencies]
creusot-std = "0.14"'
detect_manifest 'inline table'                       select '[dependencies]
creusot-std = { version = "0.14", features = ["x"] }'
detect_manifest 'table header'                       select '[dependencies.creusot-std]
version = "0.14"'
detect_manifest 'legacy name, inline'                select '[dependencies]
creusot-contracts = "0.8"'
detect_manifest 'legacy name, table header'          select '[dependencies.creusot-contracts]
version = "0.8"'
for sub in 'workspace = true' 'version = "0.14"' 'path = "../creusot-std"' 'git = "https://example.invalid/creusot"' \
           'features = ["nightly"]' 'optional = true' 'default-features = false' 'package = "creusot-std"'; do
  detect_manifest "dotted key creusot-std.${sub%% *}"       select "[dependencies]
creusot-std.$sub"
done
detect_manifest 'dotted key, legacy name'            select '[dependencies]
creusot-contracts.workspace = true'
detect_manifest 'dotted key, spaces around dot'      select '[dependencies]
creusot-std . workspace = true'
detect_manifest 'quoted dotted key'                  select '[dependencies]
"creusot-std".workspace = true'
detect_manifest 'dev-dependencies, dotted'           select '[dev-dependencies]
creusot-std.workspace = true'
detect_manifest 'build-dependencies, dotted'         select '[build-dependencies]
creusot-std.workspace = true'
detect_manifest 'target table, dotted'               select "[target.'cfg(unix)'.dependencies]
creusot-std.workspace = true"
detect_manifest 'target dev table header'            select "[target.x86_64-unknown-linux-gnu.dev-dependencies.creusot-std]
workspace = true"
detect_manifest 'trailing comment after header'      select '[dependencies] # proof library
creusot-std.workspace = true'
detect_manifest 'no creusot dependency at all'       none   '[dependencies]
serde = "1"'
detect_manifest '[features] key of the same name'    none   '[features]
creusot-std = []
creusot-contracts = ["dep:other"]
creusot-std.x = []'
detect_manifest 'commented-out inline line'          none   '[dependencies]
# creusot-std = "0.14"
  #creusot-contracts.workspace = true'
detect_manifest 'commented-out table header'         none   '# [dependencies.creusot-std]
[dependencies]
serde = "1"'
detect_manifest '[workspace.dependencies] in a package root' none '[workspace]
[workspace.dependencies]
creusot-std = "0.14"'
detect_manifest '[workspace.dependencies.creusot-std] header'   none '[workspace]
[workspace.dependencies.creusot-std]
version = "0.14"'
detect_manifest '[package.metadata] key of the same name'       none '[package.metadata.docs]
creusot-std = "0.14"'
detect_manifest 'similarly named crates'             none   '[dependencies]
my-creusot-std.workspace = true
creusot-std-extra = "1"
creusot-stdx = "1"'
detect_manifest 'CRLF line endings'                  select '[dependencies]
creusot-std.workspace = true' crlf
detect_manifest 'CRLF line endings, [features] lookalike' none '[features]
creusot-std = []' crlf
detect_manifest 'quoted table keys ["dependencies"]' select '["dependencies"]
creusot-std = "0.14"'
detect_manifest 'quoted dependency table header'     select '[dependencies."creusot-std"]
version = "0.14"'
detect_manifest 'a quoted key containing a dot is one key, not a table' none '["dependencies.creusot-std"]
version = "0.14"'
detect_manifest 'literal multiline string holding a fake table' none "[package.metadata.docs]
example = '''
[dependencies]
creusot-std = \"0.14\"
'''"
detect_manifest 'basic multiline string holding a fake table'   none '[package.metadata.docs]
example = """
[dependencies]
creusot-std.workspace = true
"""'
detect_manifest 'real dependency after a multiline string'      select '[package.metadata.docs]
example = """
[dependencies]
"""
[dependencies]
creusot-std.workspace = true'
detect_manifest 'single-line triple-quoted string does not hide what follows' select '[package.metadata]
x = """abc"""
[dependencies]
creusot-std.workspace = true'
detect_manifest 'comment mentioning a triple quote does not open a string' select '# x = """
[dependencies]
creusot-std.workspace = true'
printf '["package"]\nname = "fx"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\ncreusot-std.workspace = true\n' > "$FIX/Cargo.toml"; commit
run_phase detect
[[ "$RC" -eq 0 && "$(cat "$WORK/facts/crates")" = "." ]] && ok "selects: quoted [\"package\"] header" || { bad "quoted package header not selected"; cat "$OUT"; }
# A virtual root has no [package]: it must never be selected, even though the
# dependency is declared in it (members inherit it).
printf '[workspace]\nmembers = ["member"]\nresolver = "2"\n[workspace.dependencies]\ncreusot-std = "0.14"\ncreusot-contracts.version = "0.8"\n' > "$FIX/Cargo.toml"
rm -rf "$FIX/member"; mkdir -p "$FIX/member"; git -C "$FIX" rm -rq --cached src 2>/dev/null; mv "$FIX/src" "$FIX/member/src"
printf '[package]\nname = "fx-member"\nversion = "0.1.0"\nedition = "2021"\n' > "$FIX/member/Cargo.toml"; commit
run_phase detect
[[ "$RC" -eq 0 && -z "$(cat "$WORK/facts/crates")" ]] && grep -qx 'obligations=false' "$OUT" \
  && ok "selects nothing: virtual root with only [workspace.dependencies] and a member without the dependency" \
  || { bad "virtual root or bare member wrongly selected: crates='$(cat "$WORK/facts/crates")'"; cat "$OUT"; }
# The reported case: the member inherits through a dotted key, and only it is selected.
printf '[package]\nname = "fx-member"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\ncreusot-std.workspace = true\n' > "$FIX/member/Cargo.toml"; commit
run_phase detect
[[ "$RC" -eq 0 && "$(cat "$WORK/facts/crates")" = "member" ]] && grep -qx 'obligations=true' "$OUT" \
  && ok "virtual root + member with creusot-std.workspace = true: only the member is selected" \
  || { bad "workspace member not selected: crates='$(cat "$WORK/facts/crates")'"; cat "$OUT"; }
grep -qx 'creusot_version=0.14' "$OUT" && ok "version of an inherited dependency comes from [workspace.dependencies]" || bad "inherited version not read: $(cat "$OUT")"
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 0 ]] && grep -qx 'crates_expected=1' "$WORK/receipt" && grep -qx 'controls_passed=true' "$WORK/receipt" \
  && grep -q 'stub: selected package fx-member' "$OUT" && grep -q 'false contract refused' "$OUT" && grep -q 'true contract proved' "$OUT" \
  && ok "prove reaches the planted controls and proves the member (stub cargo-creusot)" \
  || { bad "dotted-key workspace did not reach the controls (exit $RC)"; cat "$OUT"; }
rm -rf "$FIX"; mv "$WORK/pre-detect-forms" "$FIX"

echo "== prove: an oracle that can only say yes makes the verdict VOID =="
cat > "$STAND_IN/cargo-creusot" <<'SH'
#!/usr/bin/env bash
# Initialise normally, but lie about every proof, including the false control.
if [[ "${2:-}" = "init" ]]; then
  printf '{"stand_in":true}\n' > why3find.json
fi
echo yes; exit 0
SH
run_phase prove PATH="$STAND_IN:$PATH"
[[ "$RC" -eq 2 ]] && ok "exits 2 (NO PROOF WAS PERFORMED)" || bad "exits $RC, expected 2"
grep -qx 'execution_stage=harness' "$WORK/receipt" && grep -qx 'proof_started=false' "$WORK/receipt" && ok "oracle failure is a harness outcome without caller execution" || bad "oracle failure misattributed"
grep -q 'cannot fail' "$OUT" && ok "says the prover cannot fail" || bad "no explanation"

echo "== prove: no cargo creusot at all is exit 2 =="
rm -f "$STAND_IN/cargo-creusot"
run_phase prove PATH="$STAND_IN:/usr/bin:/bin"
[[ "$RC" -eq 2 ]] && ok "exits 2 without the tool" || bad "exits $RC without the tool, expected 2"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
bash "$here/verdict-test.sh"
