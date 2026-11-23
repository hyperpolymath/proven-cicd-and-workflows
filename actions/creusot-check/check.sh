#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check.sh — the Creusot gate for Rust, parallel to the SPARK gate for Ada.
#
# Creusot (https://github.com/creusot-rs/creusot) is a deductive verifier for
# Rust: a crate depends on `creusot-std` (named `creusot-contracts` before
# v0.9.0), annotates functions with `#[requires(..)]` / `#[ensures(..)]`, and
# `cargo creusot` discharges the obligations through Why3 and SMT
# solvers. "Verified with Creusot" is therefore a claim with an oracle, and
# this gate makes the claim and the oracle agree. Three phases:
#
#   CREUSOT_GATE_PHASE=detect
#       Prints `key=value` facts: obligations (true when any crate carries a
#       Creusot dependency or contract attribute), claims (true when prose or a
#       source header asserts Creusot verification), crates (the manifest
#       directories carrying obligations, newline-separated in a file),
#       creusot_version (from the dependency spec, else "").
#
#   CREUSOT_GATE_PHASE=theatre   (the anti-theatre tier, mirrors
#                                 standards' SPARK Theatre Gate T1/T2)
#       T1  a claim with no obligations behind it: hard failure, always.
#       T2  a Creusot dependency without a supported function-bound contract:
#           warning by default; a hard failure when ENFORCE_HOLLOW=true.
#       T3  every supported source `#[trusted]` declaration is printed.
#           `trusted` is an axiom the prover takes on faith. Source inspection
#           is bounded; macro expansion and module reachability remain compiler
#           responsibilities, not a claimed complete proof-residue ledger.
#
#   CREUSOT_GATE_PHASE=prove
#       Requires `cargo creusot` on PATH (the workflow installs it, pinned).
#       FIRST proves a planted known-failing contract and REQUIRES a non-zero
#       exit; then a planted known-good one and requires zero plus a nonzero
#       proved-file denominator. A prover that
#       cannot say no is not a prover, and the verdict over the caller's
#       crate would be VOID — so the gate refuses (exit 2) rather than report
#       green. Only then does it run `cargo creusot` in every crate
#       directory that carries obligations, failing on any non-zero exit or
#       missing/zero proved-file report.
#
# Exit codes: 0 silent, 1 defect found, 2 NO CHECK WAS PERFORMED (tool
# missing, planted control misbehaved, unreadable tree). 2 is never a pass.
#
# Env: WORKING_DIRECTORY (default "."), ENFORCE_HOLLOW (default false),
#      PROVE_ARGS (--no-cache, --why3session, -j N only), CREUSOT_FACTS (path
#      the detect phase writes its crate list to; default $RUNNER_TEMP or
#      /tmp).
set -uo pipefail

# Why3find command.ml reports a singleton by filename, not "1 files".
# Both forms attest nonzero work; a bare success/zero report still cannot pass.
has_proved_files() {
  grep -qE '^Proved \([1-9][0-9]* files\)|^Proved \(verif/[^()[:cntrl:]]+\.coma\) ✔$' "$1"
}

phase="${CREUSOT_GATE_PHASE:?CREUSOT_GATE_PHASE is required: detect|theatre|prove}"
reader_manifest="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/source-facts/Cargo.toml"
dir="${WORKING_DIRECTORY:-.}"
enforce_hollow="${ENFORCE_HOLLOW:-false}"
prove_args="${PROVE_ARGS:-}"
facts_dir="${CREUSOT_FACTS:-${RUNNER_TEMP:-/tmp}/creusot-facts}"
mkdir -p "$facts_dir"
facts_dir="$(cd "$facts_dir" && pwd)"

# These are observations of this invocation, not an authenticated proof
# certificate. The workflow also checks the actual step/job conclusions.
# A setup failure must never be promoted to a failure of the caller's contracts.
execution_stage=setup
execution_outcome=unavailable
controls_passed=false
proof_started=false
proof_completed=false
crates_expected=0
crates_attempted=0
crates_completed=0
source_revision=""
record_execution() {
  local rc=$?
  if [[ "$phase" = prove ]] && [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    # Fixed keys and validated scalar values only. In particular, no compiler
    # output is allowed to write additional GitHub Actions output records.
    [[ "$source_revision" =~ ^[0-9a-f]{40}$ ]] || source_revision=""
    local suite_revision="${CREUSOT_SUITE_REVISION:-}"
    [[ "$suite_revision" =~ ^[0-9a-f]{40}$ ]] || suite_revision=""
    {
      printf 'execution_stage=%s\nexecution_outcome=%s\n' "$execution_stage" "$execution_outcome"
      printf 'controls_passed=%s\nproof_started=%s\nproof_completed=%s\n' "$controls_passed" "$proof_started" "$proof_completed"
      printf 'crates_expected=%s\ncrates_attempted=%s\ncrates_completed=%s\n' "$crates_expected" "$crates_attempted" "$crates_completed"
      printf 'source_revision=%s\nsuite_revision=%s\nproof_exit_code=%s\n' "$source_revision" "$suite_revision" "$rc"
    } >> "$GITHUB_OUTPUT" || return 2
  fi
  return "$rc"
}
trap 'record_execution' EXIT

cd "$dir" || { echo "::error::creusot-check[$phase]: cannot enter $dir — NO CHECK WAS PERFORMED." >&2; exit 2; }
source_revision="$(git rev-parse HEAD 2>/dev/null || true)"

# ---------------------------------------------------------------- facts ----
# manifest_facts — read one Cargo.toml on stdin, print `select` when the
# manifest is a package that depends on the proof library, and `version=<v>`
# for the first version string found for it. Line-oriented over the TOML
# subset Cargo manifests use; comment lines are ignored; a header's section
# decides what a key means. Exactly what selects a manifest:
#
#   1. it has a `[package]` table (a virtual workspace root is never selected;
#      it only declares `[workspace.dependencies]` for its members), AND
#   2. a dependency table T is one of `dependencies`, `dev-dependencies`,
#      `build-dependencies` (underscore spellings too), optionally prefixed
#      `target.<cfg-or-triple>.`, AND the crate N is `creusot-std` or
#      `creusot-contracts` (optionally quoted), spelled as one of
#        [T]              N = ...          inline value or inline table
#        [T]              N.<key> = ...    dotted key (workspace, version,
#                                          path, git, features, optional,
#                                          default-features, package, ...)
#        [T.N]                             table header
#
# Keys of the same name under any other table — `[features]`,
# `[package.metadata.*]`, `[workspace.dependencies]` — never select.
# CRLF line endings, quoted header keys (`["package"]`) and multiline strings
# are handled. Not recognised: a dependency renamed away from these names
# (`x = { package = "creusot-std" }`), and a header whose target
# expression itself contains `]`.
manifest_facts() {
  awk '
    function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
    # Header key path as bare components: split on unquoted dots, drop quotes
    # and padding; a dot inside a quoted component becomes \001 so that
    # "dependencies.creusot-std" is one key, not the table dependencies.creusot-std.
    function normkey(h,   i, c, q, out, cur) {
      out = ""; cur = ""; q = ""
      for (i = 1; i <= length(h); i++) {
        c = substr(h, i, 1)
        if (q != "") { if (c == q) q = ""; else cur = cur (c == "." ? "\001" : c) }
        else if (c == "\"" || c == sprintf("%c", 39)) q = c
        else if (c == ".") { out = out trim(cur) "."; cur = "" }
        else cur = cur c
      }
      return out trim(cur)
    }
    function ver_of(line, named,   v) {
      v = ""
      # `version` may be bare or quoted (TOML treats them as the same key).
      if (match(line, vre)) {
        v = substr(line, RSTART, RLENGTH)
      } else if (named && match(line, /^[^=]*=[ \t]*"[^"]+"/)) {
        v = substr(line, RSTART, RLENGTH)
      } else return ""
      sub(/^[^=]*=[ \t]*"/, "", v); sub(/".*$/, "", v)   # value = after the `=`, not the first quote
      return v
    }
    # Scan strings before interpreting headers/keys. Comments and ordinary
    # strings cannot open multiline values; only multiline state crosses lines.
    function scan_strings(line,   i, c, three, q) {
      q = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1); three = substr(line, i, 3)
        if (ml != "") {
          if (ml == "\"\"\"" && c == "\\") { i++; continue }
          if (three == ml) { ml = ""; i += 2 }
        } else if (q != "") {
          if (q == "\"" && c == "\\") i++
          else if (c == q) q = ""
        } else if (c == "#") break
        else if (three == "\"\"\"" || three == "\x27\x27\x27") { ml = three; i += 2 }
        else if (c == "\"" || c == "\x27") q = c
      }
    }
    BEGIN {
      dep  = "(dependencies|dev[-_]dependencies|build[-_]dependencies)"
      tgt  = "(target\\.[^\\[\\]]+\\.)?"
      name = "[\"\x27]?(creusot-std|creusot-contracts)[\"\x27]?"
      key  = "^[ \t]*" name "([ \t]*\\.[ \t]*([A-Za-z_-]+|\"[^\"]+\"|\x27[^\x27]+\x27))?[ \t]*="
      vre = "(^|[ \t,{.])(version|\"version\"|\x27version\x27)[ \t]*=[ \t]*\"[^\"]+\""
      vline = "^[ \t]*(version|\"version\"|\x27version\x27)[ \t]*="
      pkg = 0; sel = 0; ver = ""; kind = "other"; ml = ""
    }
    # CRLF manifests; then skip the body of multiline strings, whose lines are
    # content (never headers or keys).
    {
      sub(/\r$/, "")
      in_multiline = (ml != "")
      scan_strings($0)
      if (in_multiline) next
    }
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    /^[ \t]*\[\[/ { kind = "other"; next }
    /^[ \t]*\[/ {
      h = $0
      if (!match(h, /^[ \t]*\[[^\[\]]+\][ \t]*(#.*)?$/)) { kind = "other"; next }
      sub(/^[ \t]*\[[ \t]*/, "", h); sub(/[ \t]*\].*$/, "", h)
      h = normkey(h)
      if (h == "package") { pkg = 1; kind = "other" }
      else if (h ~ ("^" tgt dep "$")) kind = "deps"
      else if (h == "workspace.dependencies") kind = "ws"
      else if (h ~ ("^" tgt dep "\\." name "$")) { kind = "entry"; sel = 1 }
      else if (h ~ ("^workspace\\.dependencies\\." name "$")) kind = "wsentry"
      else kind = "other"
      next
    }
    kind == "deps" && $0 ~ key {
      sel = 1
      if (ver == "") ver = ver_of($0, $0 ~ ("^[ \t]*" name "[ \t]*="))
      next
    }
    kind == "ws" && $0 ~ key {
      if (ver == "") ver = ver_of($0, $0 ~ ("^[ \t]*" name "[ \t]*="))
      next
    }
    (kind == "entry" || kind == "wsentry") && $0 ~ vline {
      if (ver == "") ver = ver_of($0, 0)
    }
    END {
      if (pkg && sel) print "select"
      if (ver != "") print "version=" ver
    }
  '
}

# Tracked files only: an untracked checkout of this suite (.cicd-suite/) or a
# target/ tree must never count as the caller's sources.
list_files() { # <ere on path>
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -z | tr '\0' '\n' | grep -E "$1" || true
  else
    find . -type f -not -path '*/.git/*' -not -path '*/target/*' -not -path '*/.cicd-suite/*' \
      | sed 's#^\./##' | grep -E "$1" || true
  fi
}

manifests="$(list_files '(^|/)Cargo\.toml$')"
obligation_manifests=""
creusot_version=""
while IFS= read -r m; do
  [[ -n "$m" ]] || continue
  facts="$(manifest_facts < "$m")"
  grep -qx 'select' <<< "$facts" && obligation_manifests="${obligation_manifests}${m}"$'\n'
  if [[ -z "$creusot_version" ]]; then
    creusot_version="$(sed -n 's/^version=//p' <<< "$facts" | head -n 1)"
  fi
done <<< "$manifests"

rust_sources="$(list_files '\.rs$')"
contract_files=""
contract_count=0
trusted_count=0
if [[ -n "$rust_sources" ]]; then
  # Parse Rust attributes on function nodes instead of counting prose, string
  # literals or tokens quoted inside macros. Build from the pinned gate source
  # and Cargo.lock, outside the caller cwd so its Cargo config is not selected.
  command -v cargo >/dev/null 2>&1 || {
    echo "::error::creusot-check[$phase]: Cargo is required for the pinned Rust source reader. NO CHECK WAS PERFORMED." >&2
    exit 2
  }
  if ! (cd "${RUNNER_TEMP:-/tmp}" && cargo build --quiet --locked \
        --manifest-path "$reader_manifest" --target-dir "$facts_dir/source-target"); then
    echo "::error::creusot-check[$phase]: the pinned Rust source reader could not be built. NO CHECK WAS PERFORMED." >&2
    exit 2
  fi
  mapfile -t source_files <<< "$rust_sources"
  if ! "$facts_dir/source-target/debug/creusot-source-facts" "${source_files[@]}" > "$facts_dir/source-facts.tsv"; then
    echo "::error::creusot-check[$phase]: Rust source facts are unavailable. NO CHECK WAS PERFORMED." >&2
    exit 2
  fi
  contract_files="$(cut -f2 "$facts_dir/source-facts.tsv" | sort -u)"
  contract_count="$(awk -F '\t' '$1 == "contract" { count++ } END { print count+0 }' "$facts_dir/source-facts.tsv")"
  trusted_count="$(awk -F '\t' '$1 == "trusted" { count++ } END { print count+0 }' "$facts_dir/source-facts.tsv")"
fi

obligations=false
if [[ -n "$obligation_manifests" ]] || [[ -n "$contract_files" ]]; then obligations=true; fi

# A claim is a sentence in prose or a source HEADER that asserts the proof
# exists. Scoped to README*/docs/** and to the leading comment block of a
# Rust file, like the SPARK gate's header rule: a design note deep in a body,
# or a proposal that mentions Creusot as a plan, is not a claim about this
# tree. The negative lookbehind words ("planned", "proposal", "would", "not
# yet") are the honest-roadmap vocabulary and are excluded by hand below.
claim_re='(verified (with|by|using) creusot|creusot[- ]verified|proved (with|by|using) creusot|creusot proofs? (pass|discharged)|creusot: (all|every) (goal|obligation)s? (proved|discharged))'
plan_re='(planned|proposal|proposed|roadmap|not yet|would|future|todo|intend)'
claim_sites=""
prose="$(list_files '(^|/)(README[^/]*|[^/]*\.(adoc|md))$' | grep -vE '^(\.cicd-suite|target)/' || true)"
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    printf '%s' "$hit" | grep -qiE "$plan_re" && continue
    claim_sites="${claim_sites}${f}:${hit%%:*}"$'\n'
  done < <(grep -niE "$claim_re" "$f" 2>/dev/null || true)
done <<< "$prose"
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  header="$(awk '/^[[:space:]]*(\/\/|\/\*|\*)/ || /^[[:space:]]*$/ { print; next } { exit }' "$f")"
  if printf '%s\n' "$header" | grep -qiE "$claim_re" \
     && ! printf '%s\n' "$header" | grep -qiE "$plan_re"; then
    claim_sites="${claim_sites}${f}:1"$'\n'
  fi
done <<< "$rust_sources"
claims=false
[[ -n "$claim_sites" ]] && claims=true

crate_dirs="$(printf '%s' "$obligation_manifests" | sed -E 's#(^|/)Cargo\.toml$##; s#^$#.#' | sort -u)"
printf '%s\n' "$crate_dirs" | sed '/^$/d' > "$facts_dir/crates"
printf '%s' "$claim_sites" > "$facts_dir/claims"

case "$phase" in
  detect)
    printf 'obligations=%s\n' "$obligations"
    printf 'claims=%s\n' "$claims"
    printf 'creusot_version=%s\n' "$creusot_version"
    printf 'contract_count=%s\n' "$contract_count"
    printf 'trusted_count=%s\n' "$trusted_count"
    printf 'crates_file=%s\n' "$facts_dir/crates"
    exit 0
    ;;

  theatre)
    fail=0
    if [[ "$claims" = true ]] && [[ "$obligations" = false ]]; then
      while IFS= read -r site; do
        [[ -n "$site" ]] || continue
        echo "::error file=${site%%:*},line=${site##*:}::T1 Creusot theatre: this says the code is verified with Creusot, but no crate depends on creusot-std and no #[requires]/#[ensures] exists. Add the contracts and the dependency, or remove the claim (standards#692: Rust + Creusot, without proof theatre)."
      done <<< "$claim_sites"
      fail=1
    fi
    if [[ "$obligations" = true ]] && [[ "$contract_count" -eq 0 ]]; then
      msg="T2 hollow Creusot dependency: no supported requires/ensures attribute is bound to a function in the tracked Rust source. Add a real contract or inspect unsupported macro/configuration forms; no proof coverage is established by a dependency alone."
      if [[ "$enforce_hollow" = true ]]; then
        echo "::error::$msg"; fail=1
      else
        echo "::warning::$msg (escalates to a failure with enforce_hollow: true)"
      fi
    fi
    if [[ "$trusted_count" -gt 0 ]]; then
      echo "::notice::T3 residue: $trusted_count #[trusted] function declaration(s) found in the inspected source. These are assumptions, not discharged obligations; macro expansion and module reachability still belong to the compiler."
      awk -F '\t' '$1 == "trusted" { printf "  trusted: %s:%s\n", $2, $3 }' "$facts_dir/source-facts.tsv"
    fi
    if [[ "$obligations" = false ]] && [[ "$claims" = false ]]; then
      echo "::notice::creusot-check: no Creusot obligations and no verification claims in this tree. Nothing was proved and nothing claims to be — this gate is silent, not green-as-assurance."
    fi
    [[ "$fail" -eq 0 ]] || { echo "::error::creusot-check[theatre]: FAILED — see annotations."; exit 1; }
    echo "creusot-check[theatre]: no theatre found (obligations=$obligations claims=$claims contracts=$contract_count trusted=$trusted_count)."
    exit 0
    ;;

  prove)
    if [[ "$obligations" = false ]]; then
      echo "::error::creusot-check[prove]: no Creusot obligations in this tree — NO PROOF WAS PERFORMED. The prove job must only run when detect reported obligations=true." >&2
      exit 2
    fi
    # Unrestricted CLI arguments can narrow the proof to a positional pattern,
    # select other packages, skip translation/proving, or replace the compiler.
    # Controls do not establish coverage of omitted caller obligations. Accept
    # only operational v0.14 options that preserve package and proof scope.
    reject_prove_args() {
      echo "::error::creusot-check[prove]: unsupported PROVE_ARGS. Only --no-cache, --why3session and -j N (positive decimal) preserve this gate's proof scope. NO PROOF WAS PERFORMED." >&2
      exit 2
    }
    [[ "$prove_args" != *$'\n'* && "$prove_args" != *$'\r'* ]] || reject_prove_args
    requested_options=()
    read -r -a requested_options <<< "$prove_args"
    prove_options=()
    for ((i=0; i<${#requested_options[@]}; i++)); do
      case "${requested_options[$i]}" in
        --no-cache|--why3session) prove_options+=("${requested_options[$i]}") ;;
        -j)
          i=$((i + 1))
          [[ "${requested_options[$i]:-}" =~ ^[1-9][0-9]*$ ]] || reject_prove_args
          prove_options+=(-j "${requested_options[$i]}")
          ;;
        -j*)
          jobs="${requested_options[$i]#-j}"
          [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || reject_prove_args
          prove_options+=(-j "$jobs")
          ;;
        *) reject_prove_args ;;
      esac
    done

    if ! command -v cargo >/dev/null 2>&1 || ! cargo creusot --help >/dev/null 2>&1; then
      echo "::error::creusot-check[prove]: 'cargo creusot' is not available — NO PROOF WAS PERFORMED. The workflow installs Creusot (pinned) before this step." >&2
      exit 2
    fi

    # Creusot v0.14 resolves Why3find configuration at Cargo's workspace
    # root, and its default package selection may include other members.
    # Resolve the real workspace and select the identified package explicitly;
    # a member-local or ambient configuration is not a valid substitute.
    command -v jq >/dev/null 2>&1 || {
      echo "::error::creusot-check[prove]: jq is required to read Cargo metadata. NO PROOF WAS PERFORMED." >&2
      exit 2
    }
    source_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    source_root="$(cd "$source_root" && pwd -P)" || exit 2
    : > "$facts_dir/proof-plan"
    while IFS= read -r crate; do
      [[ -n "$crate" ]] || continue
      manifest_path="$(realpath -e -- "$crate/Cargo.toml")" || exit 2
      case "$manifest_path" in
        "$source_root"/*) ;;
        *) echo "::error::creusot-check[prove]: selected manifest escapes the source repository. NO PROOF WAS PERFORMED." >&2; exit 2 ;;
      esac
      if ! metadata="$(cargo metadata --format-version 1 --no-deps --manifest-path "$manifest_path")"; then
        echo "::error file=$crate/Cargo.toml::creusot-check[prove]: Cargo metadata could not resolve this crate. NO PROOF WAS PERFORMED." >&2
        exit 2
      fi
      workspace_root="$(jq -er '.workspace_root | select(type == "string" and length > 0)' <<< "$metadata")" || exit 2
      workspace_root="$(cd "$workspace_root" && pwd -P)" || exit 2
      case "$workspace_root" in
        "$source_root"|"$source_root"/*) ;;
        *) echo "::error::creusot-check[prove]: Cargo workspace is outside the source repository. NO PROOF WAS PERFORMED." >&2; exit 2 ;;
      esac
      package="$(jq -er --arg manifest "$manifest_path" '[.packages[] | select(.manifest_path == $manifest) | .name] | if length == 1 then .[0] else empty end' <<< "$metadata")" || {
        # A virtual workspace can declare creusot-std for its members, but is
        # not itself an executable package. Member manifests are selected by
        # the same detector; zero actual packages below remains unavailable.
        if [[ "$manifest_path" = "$workspace_root/Cargo.toml" ]]; then
          continue
        fi
        echo "::error file=$crate/Cargo.toml::creusot-check[prove]: no unique package matches the selected manifest. NO PROOF WAS PERFORMED." >&2
        exit 2
      }
      if [[ ! "$package" =~ ^[A-Za-z0-9_-]+$ ]] || [[ "$crate" = *$'\t'* ]]; then
        echo "::error::creusot-check[prove]: unsupported package or manifest path. NO PROOF WAS PERFORMED." >&2
        exit 2
      fi
      if [[ ! -s "$workspace_root/why3find.json" ]]; then
        echo "::error file=$workspace_root/why3find.json::creusot-check[prove]: missing Cargo workspace Why3find configuration. NO PROOF WAS PERFORMED." >&2
        exit 2
      fi
      configuration_path="$(realpath -e -- "$workspace_root/why3find.json")" || exit 2
      case "$configuration_path" in
        "$source_root"/*) ;;
        *) echo "::error::creusot-check[prove]: Why3find configuration escapes the source repository. NO PROOF WAS PERFORMED." >&2; exit 2 ;;
      esac
      if ! jq -e 'type == "object"' "$configuration_path" >/dev/null; then
        echo "::error file=$workspace_root/why3find.json::creusot-check[prove]: malformed Why3find configuration. NO PROOF WAS PERFORMED." >&2
        exit 2
      fi
      printf '%s\t%s\n' "$crate" "$package" >> "$facts_dir/proof-plan"
      crates_expected=$((crates_expected + 1))
    done < "$facts_dir/crates"
    # Source-level attributes alone do not identify an executable Cargo target.
    # An empty crate list must not execute zero commands and still pass.
    if [[ "$crates_expected" -eq 0 ]]; then
      echo "::error::creusot-check[prove]: obligations were detected but no Cargo package was selected. NO PROOF WAS PERFORMED." >&2
      exit 2
    fi

    # ---- planted controls: the prover must be able to say NO -------------
    execution_stage=harness
    execution_outcome=failed
    ctl="$(mktemp -d)"
    # Create a named control crate under $ctl from the supplied Rust source.
    # If initialisation fails or why3find.json is missing or empty, remove $ctl
    # and exit 2 (no proof performed).
    plant() { # <name> <body>
      mkdir -p "$ctl/$1/src"
      cat > "$ctl/$1/Cargo.toml" <<TOML
[package]
name = "$1"
version = "0.0.0"
edition = "2021"
[dependencies]
creusot-std = "${creusot_version:-*}"
TOML
      printf '%s\n' "$2" > "$ctl/$1/src/lib.rs"
      # v0.14 init copies the installed Why3find configuration into this
      # private control crate. Never initialise or rewrite the caller's tree.
      if ! (cd "$ctl/$1" && cargo creusot init "$1") || [[ ! -s "$ctl/$1/why3find.json" ]]; then
        echo "::error::creusot-check[prove]: control initialisation did not supply why3find.json. NO PROOF WAS PERFORMED." >&2
        rm -rf "$ctl"; exit 2
      fi
    }
    plant creusot-control-failing 'use creusot_std::prelude::*;
#[ensures(result == 0u32)]
pub fn planted_must_fail() -> u32 { 1 }'
    plant creusot-control-passing 'use creusot_std::prelude::*;
#[ensures(result == 2u32)]
pub fn planted_must_pass() -> u32 { 2 }'
    echo "::group::planted control: a false postcondition must NOT prove"
    if (cd "$ctl/creusot-control-failing" && cargo creusot "${prove_options[@]}"); then
      echo "::endgroup::"
      echo "::error::creusot-check[prove]: the planted FALSE contract was reported proved (exit 0). This prover cannot fail, so any verdict it gives over the caller's crate is VOID. NO PROOF WAS PERFORMED." >&2
      rm -rf "$ctl"; exit 2
    fi
    echo "::endgroup::"
    echo "planted control: false contract refused — the oracle can say no."
    echo "::group::planted control: a true postcondition must prove"
    if ! (cd "$ctl/creusot-control-passing" && cargo creusot "${prove_options[@]}") > "$facts_dir/positive-control.log" 2>&1; then
      echo "::endgroup::"
      cat "$facts_dir/positive-control.log"
      echo "::error::creusot-check[prove]: the planted TRUE contract did not prove. The toolchain is broken (solver or prelude), so a red on the caller's crate would be misattributed. NO PROOF WAS PERFORMED." >&2
      rm -rf "$ctl"; exit 2
    fi
    cat "$facts_dir/positive-control.log"
    if ! has_proved_files "$facts_dir/positive-control.log"; then
      echo "::endgroup::"
      echo "::error::creusot-check[prove]: the positive control reported no nonzero proved-file denominator. NO CALLER PROOF WAS PERFORMED." >&2
      rm -rf "$ctl"; exit 2
    fi
    echo "::endgroup::"
    rm -rf "$ctl"
    echo "planted control: true contract proved — the oracle can say yes."
    controls_passed=true

    # ---- the caller's crates ---------------------------------------------
    execution_stage=substantive
    execution_outcome=unavailable
    fail=0
    unavailable=0
    while IFS=$'\t' read -r crate package; do
      [[ -n "$crate" ]] || continue
      echo "::group::cargo creusot — $crate (package $package)"
      proof_started=true
      crates_attempted=$((crates_attempted + 1))
      proof_log="$facts_dir/caller-$crates_attempted.log"
      if (cd "$crate" && cargo creusot -p "$package" "${prove_options[@]}") > "$proof_log" 2>&1; then
        cat "$proof_log"
        echo "::endgroup::"
        if has_proved_files "$proof_log"; then
          echo "ok: $crate — cargo creusot completed with a nonzero proved-file denominator"
        else
          echo "::error file=$crate/Cargo.toml::creusot-check[prove]: the command exited zero but reported no nonzero proved-file denominator; proof coverage is unavailable."
          unavailable=1
        fi
      else
        rc=$?
        cat "$proof_log"
        echo "::endgroup::"
        echo "::error file=$crate/Cargo.toml::creusot-check[prove]: 'cargo creusot' exited $rc in $crate. The policy step ran; inspect its report to distinguish translation, dependency, solver and obligation failures. This exit alone does not show that a contract is false."
        fail=1
      fi
      crates_completed=$((crates_completed + 1))
    done < "$facts_dir/proof-plan"
    proof_completed=true
    execution_outcome=failed
    [[ "$fail" -eq 0 ]] || exit 1
    execution_outcome=unavailable
    [[ "$unavailable" -eq 0 ]] || exit 2
    execution_outcome=passed
    echo "creusot-check[prove]: controls passed and all $crates_completed selected crate commands completed successfully (source-detected trusted axioms: $trusted_count)."
    exit 0
    ;;
  *)
    echo "::error::creusot-check: unknown phase '$phase' (detect|theatre|prove)" >&2
    exit 2
    ;;
esac
