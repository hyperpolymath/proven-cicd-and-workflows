#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# advisory-autofix.sh — the advisory auto-fix must be able to FAIL, for each
# thing it claims, before any repository schedules it.
#
# Controls (each asserted, and each killed by a planted mutant of the scripts):
#   P  positive   a lockfile pinning smallvec 1.6.0 (RUSTSEC-2021-0003, patched
#                 in 1.6.1) is bumped to EXACTLY 1.6.1 (the lowest patched
#                 version, not the newest 1.x), the report lists it, and the
#                 re-audit is clean.
#   N  negative   an advisory with NO patched version changes no lockfile and
#                 is reported as an issue, never as a bump.
#   M  multi      a root workspace AND a nested fuzz/ workspace are both
#                 found and both bumped; a vendored Cargo.lock is not touched;
#                 an untracked Cargo.lock is not even discovered.
#   A  two advisories on ONE crate (different patched versions) are cured by one
#                 consistent bump, with no false issue.
#   I  the SAME advisory in two workspaces is ONE issue listing both.
#   S  the bot branch is reused only if it is exactly the intended change.
#   W  the default audit and update run inside each workspace directory.
#   G  dependabot  the generated dependabot.yml has a cargo entry for every workspace
#                 (root + fuzz/), security-only (limit 0, no semver-patch ignore).
#   L  live       when cargo-deny is installed, the REAL audit finds the
#                 advisory in the P fixture and, after the fix, finds none.
#                 REQUIRE_LIVE=1 (CI) makes a missing cargo-deny exit 2 —
#                 a control that did not run is void, not green.
#
# The audit oracle in P/N/M is audit-standin.sh replaying recorded real
# cargo-deny output; `cargo update --precise` runs for real against the
# crates.io index, so the network is required (exit 2 without it).
#
# Exit 0 all controls hold; 1 a control failed; 2 a control could not run.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fx="$root/tests/fixtures/advisory-autofix"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*" >&2; fail=1; }
for t in jq cargo git sort; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done

# Fake `gh` and `cargo` for the delivery and cwd controls. They log every call
# and answer only what the scripts ask; they never touch the network.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
echo "$*" | sed -E 's/^api -X ([A-Z]+)/PATCHLIKE \1 api/' >>"${FAKE_LOG:-/dev/null}"
args="$*"; jqx=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && jqx="$a"; prev="$a"; done
emit() { if [ -n "$jqx" ]; then jq -r "$jqx" <<<"$1"; else printf '%s\n' "$1"; fi; }
case "$args" in
  *"-X PATCH"*|*"-X POST"*|"api graphql"*) echo "PATCH $args" >>"${FAKE_LOG:-/dev/null}"; exit 0 ;;
  "api repos/"*"/git/ref/heads/main"*) emit "{\"object\":{\"sha\":\"$FAKE_BASE\"}}" ;;
  "api repos/"*"/git/ref/heads/advisory-autofix"*) emit '{"object":{"sha":"x"}}' ;;
  "api repos/"*"/compare/"*) emit "$(jq -n --argjson f "$FAKE_FILES" --argjson a "$FAKE_AHEAD" --argjson b "$FAKE_BEHIND" '{ahead_by:$a,behind_by:$b,files:($f|map({filename:.}))}')" ;;
  "api repos/"*"/contents/"*) emit "$(jq -n --arg c "$FAKE_CONTENT" '{content:$c}')" ;;
  "pr list"*) exit 0 ;;
  "pr create"*) echo "pr create" >>"${FAKE_LOG:-/dev/null}"; exit 0 ;;
  *) exit 0 ;;
esac
FAKEGH
cat > "$work/bin/cargo" <<'FAKECARGO'
#!/usr/bin/env bash
# deny: replay the stand-in oracle for this directory; update: edit the lock.
case "$1" in
  deny) echo "deny $PWD" >>"$FAKE_LOG"; "$STANDIN" "$PWD"; exit $? ;;
  update)
    echo "update $PWD" >>"$FAKE_LOG"
    t=""; prev=""; for a in "$@"; do [ "$prev" = "--precise" ] && t="$a"; prev="$a"; done
    sed -i "/^name = \"smallvec\"/{n;s/version = \".*\"/version = \"$t\"/}" Cargo.lock; exit 0 ;;
esac
exit 0
FAKECARGO
chmod +x "$work/bin/gh" "$work/bin/cargo"

# new_repo <name> <dir>...: a git repo with the ws fixture in each <dir>
new_repo() {
  local r="$work/$1"; shift
  mkdir -p "$r"; git -C "$r" init -q; git -C "$r" config user.email t@example.invalid; git -C "$r" config user.name t
  local d
  for d in "$@"; do mkdir -p "$r/$d"; cp -r "$fx/ws/." "$r/$d/"; done
  git -C "$r" add -A; git -C "$r" commit -q -m fixture
  echo "$r"
}
locked() { awk '/^name = "smallvec"/{getline; gsub(/[^0-9.]/,"",$0); print; exit}' "$1/Cargo.lock"; }
# run_fix <repo> <scripts-dir> [env...]: runs the fix, returns its exit code
run_fix() {
  local r="$1" s="$2"; shift 2
  ( cd "$r" && env AUDIT_CMD="$fx/audit-standin.sh" REPORT="$r/report.json" "$@" bash "$s/advisory-autofix-fix.sh" >"$r/fix.log" 2>&1 )
}
# One control run against a scripts directory (real or mutated). Prints
# nothing but sets $fail via ok/bad; $1 = label prefix.
controls() {
  local s="$1" tag="$2" r rc
  unit "$s"

  r="$(new_repo "p-$tag" .)"; rc=0; run_fix "$r" "$s" || rc=$?
  # A failed `cargo update` is an issue in the report (exit 0), not exit 2. If it
  # failed for want of the registry, this is the environment, not a script defect.
  if [ "$rc" -eq 0 ] && jq -r '.workspaces[0].issues[]?.reason' "$r/report.json" 2>/dev/null | grep -i 'cargo update --precise .* failed' | grep -qi 'network\|index\|resolve\|download\|spurious\|timed out'; then
    echo "advisory-autofix: cargo update could not reach the registry; control P could not run" >&2; exit 2
  fi
  if [ "$rc" -eq 0 ] && [ "$(locked "$r")" = 1.6.1 ] \
     && jq -e '.workspaces[0] | .bumped[0].crate=="smallvec" and .bumped[0].from=="1.6.0" and .bumped[0].to=="1.6.1" and .clean_after==true' "$r/report.json" >/dev/null \
     && jq -e '.changed|length==1' "$r/report.json" >/dev/null; then
    ok "P positive: smallvec 1.6.0 -> exactly 1.6.1, re-audit clean"
  else bad "P positive: locked=$(locked "$r") rc=$rc ($(tr '\n' ' ' <"$r/fix.log" | tail -c 300))"; fi

  r="$(new_repo "n-$tag" .)"; rc=0; run_fix "$r" "$s" STANDIN_NO_PATCH=1 || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(locked "$r")" = 1.6.0 ] \
     && jq -e '(.workspaces[0].bumped|length)==0 and (.workspaces[0].issues[0].id=="RUSTSEC-2021-0003") and (.changed|length)==0 and .workspaces[0].clean_after==false' "$r/report.json" >/dev/null; then
    ok "N negative: no patched version -> issue, lockfile untouched"
  else bad "N negative: locked=$(locked "$r") rc=$rc report=$(jq -c . "$r/report.json" 2>/dev/null | head -c 300)"; fi

  r="$(new_repo "m-$tag" . fuzz vendor/dep)"
  cp "$fx/ws/Cargo.lock" "$r/untracked.lock.tmp"; mkdir -p "$r/scratch"; cp -r "$fx/ws/." "$r/scratch/"
  printf 'scratch/\n' >"$r/.gitignore"; git -C "$r" add .gitignore; git -C "$r" commit -q -m ignore
  rc=0; run_fix "$r" "$s" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(locked "$r")" = 1.6.1 ] && [ "$(locked "$r/fuzz")" = 1.6.1 ] \
     && [ "$(locked "$r/vendor/dep")" = 1.6.0 ] && [ "$(locked "$r/scratch")" = 1.6.0 ] \
     && jq -e '(.workspaces|map(.dir)|sort)==[".","fuzz"]' "$r/report.json" >/dev/null; then
    ok "M multi: root + fuzz/ bumped; vendored and untracked lockfiles untouched"
  else bad "M multi: root=$(locked "$r") fuzz=$(locked "$r/fuzz") vendor=$(locked "$r/vendor/dep") dirs=$(jq -c '[.workspaces[].dir]' "$r/report.json" 2>/dev/null)"; fi

  r="$(new_repo "a-$tag" .)"; rc=0; run_fix "$r" "$s" STANDIN_TWO=1 || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(locked "$r")" = 1.7.0 ] \
     && jq -e '.workspaces[0] | (.issues|length)==0 and .clean_after==true and (.bumped|length)>=1' "$r/report.json" >/dev/null; then
    ok "A two advisories on one crate: one consistent bump to 1.7.0, no false issue"
  else bad "A two advisories: locked=$(locked "$r") rc=$rc report=$(jq -c . "$r/report.json" 2>/dev/null | head -c 400)"; fi

  # I issues: the SAME advisory in two workspaces is ONE issue listing both
  r="$(new_repo "i-$tag" .)"
  jq -n '{workspaces:[{dir:".",bumped:[],issues:[{id:"RUSTSEC-X",crate:"foo",version:"1.0.0",reason:"no patched version exists"}],clean_after:false},{dir:"fuzz",bumped:[],issues:[{id:"RUSTSEC-X",crate:"foo",version:"1.0.1",reason:"no patched version exists"}],clean_after:false}],changed:[]}' >"$r/report.json"
  out="$( cd "$r" && DRY_RUN=1 GH_REPO=o/r BASE_BRANCH=main REPORT="$r/report.json" bash "$s/advisory-autofix-deliver.sh" 2>&1 || true )"
  if [ "$(grep -c 'DRY: gh issue create' <<<"$out")" = 1 ] && grep -q 'workspace `fuzz`' <<<"$out" && grep -q 'workspace `\.`' <<<"$out"; then
    ok "I issues: one issue for the same advisory across two workspaces, listing both"
  else bad "I issues: $(tr '\n' ' ' <<<"$out" | head -c 300)"; fi

  # S stale bot branch: reused only when it is exactly the intended change
  r="$(new_repo "s-$tag" .)"
  jq -n '{workspaces:[{dir:".",bumped:[{id:"A",crate:"smallvec",from:"1.6.0",to:"1.6.1"}],issues:[],clean_after:true}],changed:["./Cargo.lock"]}' >"$r/report.json"
  sed -i 's/version = "1.6.0"/version = "1.6.1"/' "$r/Cargo.lock"
  base="$(git -C "$r" rev-parse HEAD)"
  stale_run() { # <files-json> <ahead> <behind> -> prints the fake-gh call log
    rm -f "$r/gh.log"
    ( cd "$r" && PATH="$work/bin:$PATH" FAKE_LOG="$r/gh.log" FAKE_BASE="$base" FAKE_FILES="$1" FAKE_AHEAD="$2" FAKE_BEHIND="$3" FAKE_CONTENT="$(base64 -w0 "$r/Cargo.lock")" \
        GH_REPO=o/r BASE_BRANCH=main AUTOFIX_TOKEN=t REPORT="$r/report.json" bash "$s/advisory-autofix-deliver.sh" >/dev/null 2>&1 || true ); cat "$r/gh.log" 2>/dev/null
  }
  exact="$(stale_run '["Cargo.lock"]' 1 0)"
  extra="$(stale_run '["Cargo.lock","fuzz/Cargo.lock"]' 1 0)"
  behind="$(stale_run '["Cargo.lock"]' 1 3)"
  if ! grep -q 'PATCH' <<<"$exact" && grep -q 'pr create' <<<"$exact" \
     && grep -q 'PATCH' <<<"$extra" && grep -q 'PATCH' <<<"$behind"; then
    ok "S stale branch: exact branch reused (PR still ensured); extra files or old base rebuilt"
  else bad "S stale branch: exact=[$(tr '\n' '|' <<<"$exact")] extra=[$(tr '\n' '|' <<<"$extra")] behind=[$(tr '\n' '|' <<<"$behind")]"; fi

  # W workspace cwd: the default audit and update run INSIDE the workspace
  r="$(new_repo "w-$tag" fuzz)"; rc=0
  ( cd "$r" && PATH="$work/bin:$PATH" FAKE_LOG="$r/cargo.log" STANDIN="$fx/audit-standin.sh" REPORT="$r/report.json" bash "$s/advisory-autofix-fix.sh" >"$r/fix.log" 2>&1 ) || rc=$?
  if [ "$rc" -eq 0 ] && grep -q '^deny .*/fuzz$' "$r/cargo.log" && grep -q '^update .*/fuzz$' "$r/cargo.log" \
     && ! grep -qE '^(deny|update) .*/w-[a-z0-9-]*$' "$r/cargo.log"; then
    ok "W workspace cwd: cargo deny and cargo update ran inside fuzz/"
  else bad "W workspace cwd: rc=$rc log=[$(tr '\n' '|' <"$r/cargo.log" 2>/dev/null)]"; fi

  # G dependabot: one cargo entry per discovered workspace (root and fuzz/, not vendor/)
  r="$(new_repo "g-$tag" . fuzz vendor/dep)"
  if bash "$s/advisory-autofix-dependabot.sh" "$r" >"$r/dependabot.yml" 2>/dev/null \
     && [ "$(grep -c 'package-ecosystem: "cargo"' "$r/dependabot.yml")" = 2 ] \
     && [ "$(grep -o 'directory: "[^"]*"' "$r/dependabot.yml" | tr '\n' ' ')" = 'directory: "/" directory: "/fuzz" ' ] \
     && [ "$(grep -c 'open-pull-requests-limit: 0,' "$r/dependabot.yml")" = 2 ] \
     && ! grep -q 'semver-patch' "$r/dependabot.yml"; then
    ok "G dependabot: cargo entry for / and /fuzz, security-only, no semver-patch ignore"
  else bad "G dependabot: $(tr '\n' ' ' <"$r/dependabot.yml" | head -c 300)"; fi
}


# U unit: with several compatible patched ranges the planner picks the LOWEST,
# skips a range that needs a major bump, and routes a strict bound to an issue.
unit() {
  local s="$1" row
  pf() { jq -c --arg s "Solution: $1" --arg v "$2" 'select(.type=="diagnostic") | (.fields.notes) |= map(if startswith("Solution:") then $s else . end) | (.fields.graphs[0].Krate.version) |= $v' "$fx/deny-smallvec-1.6.0.jsonl" | bash "$s/advisory-autofix-plan.sh"; }
  row="$(pf 'Upgrade to >=1.7.2 OR >=1.6.5, <1.7.0 OR >=0.6.14, <1.0.0 (try `cargo update -p smallvec`)' 1.6.0 | cut -f1,5)"
  [ "$row" = "$(printf 'bump\t1.6.5')" ] && ok "U unit: lowest compatible patched range wins (1.6.5, not 1.7.2)" || bad "U unit lowest: got '$row'"
  row="$(pf 'Upgrade to >=2.0.1' 1.6.0 | cut -f1,5)"
  [ "$row" = "$(printf 'issue\t-')" ] && ok "U unit: patch only across a major -> issue" || bad "U unit major: got '$row'"
  row="$(pf 'Upgrade to >1.6.0' 1.6.0 | cut -f1,5)"
  [ "$row" = "$(printf 'issue\t-')" ] && ok "U unit: strict lower bound -> issue" || bad "U unit strict: got '$row'"
  row="$(pf 'Upgrade to >=0.3.9 OR >=0.4.2' 0.3.1 | cut -f1,5)"
  [ "$row" = "$(printf 'bump\t0.3.9')" ] && ok "U unit: 0.x lineage stays inside its minor (0.3.9, not 0.4.2)" || bad "U unit 0.x: got '$row'"
}
echo "== real scripts =="
controls "$root/scripts" real

# Mutants: each plants one defect and MUST turn a control red, or the control
# proves nothing about that behaviour.
mutate() { # <name> <file> <sed-expr>
  local d="$work/mut-$1"; mkdir -p "$d"; cp "$root"/scripts/advisory-autofix-*.sh "$d/"
  sed -i "$3" "$d/$2"
  if cmp -s "$d/$2" "$root/scripts/$2"; then echo "mutant $1 changed nothing; the sed expression is stale" >&2; exit 2; fi
  echo "== mutant $1 (every line below marked FAIL is a control doing its job) =="
  local before=$fail; fail=0
  controls "$d" "$1" >"$d.out" 2>&1 || true; sed "s/^/    /" "$d.out"
  if [ "$fail" -eq 0 ]; then fail=$before; bad "mutant $1 survived: no control caught it"; else fail=$before; ok "mutant $1 killed"; fi
}
mutate highest   advisory-autofix-plan.sh     's/lt "\$lower" "\$best"/lt "\$best" "\$lower"/'
mutate rootonly  advisory-autofix-discover.sh "s#git ls-files -z -- 'Cargo.lock' '\*\*/Cargo.lock'#git ls-files -z -- 'Cargo.lock'#"
mutate vendored  advisory-autofix-discover.sh 's#\*/vendor/\*|##'
mutate onedir advisory-autofix-dependabot.sh 's/^for d in .*; do$/for d in "${dirs[0]}"; do/'
mutate onebump   advisory-autofix-fix.sh      's/:-4}"/:-1}"/; s/sort -V | tail -n1)"$/sort -V | head -n1)"/'
mutate claimclean advisory-autofix-fix.sh     's/^  clean=false; plan=""; unaudited=0/  clean=true; plan=""; unaudited=0/'
mutate oneperws  advisory-autofix-deliver.sh  's/| group_by(\[.id, .crate\])\[\]/| map({id,crate,items:[{dir,version,reason}]})[]/'
mutate pathsonly advisory-autofix-deliver.sh  '/ahead_by/s/!= 1/== 99/; /behind_by/s/!= 0/== 99/; s/\[ "\$want" != "\$have_files" \]/false/'
mutate rootcwd   advisory-autofix-fix.sh      's/( cd "\$dir" \&\& cargo deny/( cargo deny/; s/\$(cd "\$dir" \&\& cargo update/$(cargo update/'

echo "== L live cargo-deny =="
if command -v cargo-deny >/dev/null 2>&1; then
  r="$(new_repo live .)"; rc=0
  ( cd "$r" && REPORT="$r/report.json" bash "$root/scripts/advisory-autofix-fix.sh" >"$r/fix.log" 2>&1 ) || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(locked "$r")" = 1.6.1 ] && jq -e '.workspaces[0].clean_after==true and .workspaces[0].bumped[0].id=="RUSTSEC-2021-0003"' "$r/report.json" >/dev/null; then
    ok "L live: real cargo-deny found RUSTSEC-2021-0003, fix bumped to 1.6.1, real re-audit clean"
  else bad "L live: rc=$rc locked=$(locked "$r") $(tail -n 5 "$r/fix.log" | tr '\n' ' ')"; fi
elif [ "${REQUIRE_LIVE:-}" = 1 ]; then
  echo "cargo-deny is required (REQUIRE_LIVE=1); the live control did not run" >&2; exit 2
else
  echo "  skip  L live: cargo-deny not installed (REQUIRE_LIVE=1 makes this fatal; CI sets it)"
fi

[ "$fail" -eq 0 ] || { echo "advisory-autofix controls: FAILED" >&2; exit 1; }
echo "advisory-autofix controls passed."
