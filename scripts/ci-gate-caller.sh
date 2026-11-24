#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# ci-gate-caller.sh — render and drift-check the CI/gate caller in a consumer checkout.
#
#   ci-gate-caller.sh render --suite DIR --suite-sha <40hex> --repo OWNER/NAME --checkout DIR
#                            [--skip-consumer-checker]
#   ci-gate-caller.sh check  --suite DIR --checkout DIR [--repo OWNER/NAME]
#
# render  Writes <checkout>/.github/workflows/ci-gate.yml from templates/ci-gate-caller.yml AS IT
#         WAS at <suite-sha> (git show from the local suite clone DIR; no network), with
#         __CICD_SUITE_SHA__ replaced. It refuses unless profiles/ci-gate/<owner>/<name>.json exists
#         at that SHA and passes validate-ci-gate-profile.sh (this checkout's validator). If the
#         checkout has .github/workflows/actions.lock, the reusable caller is listed as the EMPTY
#         file-level entry  '.github/workflows/ci-gate.yml': []  with no leaf record (a leaf record
#         fails `gh actions-lock` as "Unused lockfile entry", no entry as "not-pinned"). The retired
#         pull_request_target guard caller (.github/workflows/ci-gate-tamper-guard*.yml that calls
#         the suite) and its lock entry are removed. Idempotent: a second run changes nothing.
#
#         Finally, if <checkout>/scripts/check-lock-sync.sh exists it is run from the checkout (the
#         consumer's own lock gate; never vendored or replaced). If it fails, render exits 1 with
#         `REFUSED consumer-lock-checker` and its output, leaving the written files in place for the
#         operator. --skip-consumer-checker is the deliberate override; the summary says it was skipped.
#
# check   Writes nothing. Reports drift and exits 1 when there is any. Drift kinds (printed as
#         `DRIFT <kind>: <detail>`):
#           caller-missing        no .github/workflows/ci-gate.yml
#           pin-missing           the caller has no suite pin at all
#           pin-not-40hex         a suite pin that is not a lowercase 40-hex SHA
#           pin-inconsistent      the caller's suite pins differ from each other
#           pin-unknown-to-suite  the pinned SHA is not a commit in the suite clone
#           caller-differs        the caller differs from the template AT ITS OWN PINNED SHA
#           profile-missing       (only with --repo) no valid profile at the pinned SHA
#           lock-entry-missing    actions.lock has no ci-gate.yml entry
#           lock-entry-not-empty  actions.lock has a leaf record under ci-gate.yml (must be [])
#           lock-extra-entry      actions.lock still lists a retired guard caller
#           guard-caller-leftover a retired guard caller file is still present
#
# Needs bash, git, jq, and mikefarah (Go) yq v4. Fails closed: every error is non-zero and nothing
# is treated as clean unless it was positively checked.
# Exit: 0 ok/clean; 1 refusal or drift; 2 usage or tool error; 3 untested actions.lock schema.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SUITE_REPO=hyperpolymath/proven-cicd-and-workflows
CALLER_REL=.github/workflows/ci-gate.yml
LOCK_REL=.github/workflows/actions.lock
KNOWN_LOCK_VERSIONS="v0.0.2 v0.0.3"   # same list as deonboard-workflow.sh

die()  { echo "ci-gate-caller.sh: $*" >&2; exit "${2:-1}"; }
usage() { sed -n '4,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

command -v git >/dev/null || die 'git required' 2
command -v jq  >/dev/null || die 'jq required' 2
yq --version 2>/dev/null | grep -q mikefarah || die 'mikefarah yq v4 required (https://github.com/mikefarah/yq); another yq is on PATH' 2

[[ $# -ge 1 ]] || usage
mode=$1; shift
[[ $mode == render || $mode == check ]] || usage
suite='' sha='' repo='' checkout=''
skip_checker=0
while [[ $# -gt 0 ]]; do
  if [[ $1 == --skip-consumer-checker ]]; then skip_checker=1; shift; continue; fi
  [[ $# -ge 2 ]] || die "option $1 needs a value" 2
  case $1 in
    --suite) suite=$2 ;; --suite-sha) sha=$2 ;; --repo) repo=$2 ;; --checkout) checkout=$2 ;;
    *) die "unknown option $1" 2 ;;
  esac
  shift 2
done
[[ -n $suite && -d $suite ]]       || die '--suite DIR (a local clone of the suite) is required' 2
[[ -n $checkout && -d $checkout ]] || die '--checkout DIR is required and must exist' 2
git -C "$suite" rev-parse --git-dir >/dev/null 2>&1 || die "--suite $suite is not a git repository" 2
if [[ -n $repo ]]; then
  [[ $repo =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ && $repo != *..* ]] \
    || die "--repo '$repo' is not OWNER/NAME" 2
fi
is_sha() { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
wf_dir="$checkout/.github/workflows"
caller="$checkout/$CALLER_REL"
lock="$checkout/$LOCK_REL"

# Template as it was at $1, with the pin substituted, into $2. Returns non-zero when absent.
render_template() {
  local at=$1 out=$2
  git -C "$suite" cat-file -e "${at}^{commit}" 2>/dev/null || return 3
  git -C "$suite" show "${at}:templates/ci-gate-caller.yml" > "$out.raw" 2>/dev/null || return 4
  grep -q '__CICD_SUITE_SHA__' "$out.raw" || return 5
  sed "s/__CICD_SUITE_SHA__/$at/g" "$out.raw" > "$out"
  ! grep -q '__CICD_SUITE_SHA__' "$out" || return 5
}
# Profile for $2 at $1 into $3, validated. 0 valid; 1 missing or invalid.
profile_ok() {
  local at=$1 r=$2 out=$3
  git -C "$suite" show "${at}:profiles/ci-gate/${r}.json" > "$out" 2>/dev/null || return 1
  bash "$ROOT/scripts/validate-ci-gate-profile.sh" "$out" "$r" >/dev/null 2>&1 || return 1
}
# True when workflow file $1 has a job whose `uses:` is the suite's tamper-guard reusable (block or
# flow style; parsed, not grepped). An unparseable file is an error, not "no".
calls_guard() {
  local u
  u=$(yq -r '(.jobs // {}) | to_entries | .[] | .value.uses // ""' "$1") || die "cannot parse $1" 2
  grep -Eq "^$SUITE_REPO/\.github/workflows/ci-gate-tamper-guard\.ya?ml@" <<<"$u"
}
# Retired guard callers present on disk: files named ci-gate-tamper-guard*.yml|yaml that call the suite.
guard_files() {
  local f
  for f in "$wf_dir"/ci-gate-tamper-guard*.yml "$wf_dir"/ci-gate-tamper-guard*.yaml; do
    [[ -f $f ]] || continue
    if calls_guard "$f"; then echo "$f"; fi
  done
  return 0
}
# Lock keys of retired guard callers: guard-named keys whose file is gone, or still calls the suite.
# A guard-named file that does NOT call the suite keeps its record.
retired_lock_keys() {
  local k
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    if [[ ! -f $checkout/$k ]] || calls_guard "$checkout/$k"; then echo "$k"; fi
  done < <(yq '.workflows | keys | .[] | select(test("^\\.github/workflows/ci-gate-tamper-guard[^/]*\\.ya?ml$"))' "$lock")
}
lock_check_schema() {
  local v
  v=$(yq '.version' "$lock") || die "$lock is unreadable" 3
  case " $KNOWN_LOCK_VERSIONS " in *" $v "*) ;; *) die "actions.lock schema '$v' is untested (tested: $KNOWN_LOCK_VERSIONS)" 3 ;; esac
  [[ $(yq '.workflows | tag' "$lock") == '!!map' ]] || die "$lock has no workflows map" 3
}
lock_state() { # ci-gate.yml entry: absent | empty | leaf
  if ! w=$CALLER_REL yq -e '.workflows | has(strenv(w))' "$lock" >/dev/null 2>&1; then echo absent
  elif [[ $(w=$CALLER_REL yq -o=json -I0 '.workflows[strenv(w)]' "$lock") == '[]' ]]; then echo empty
  else echo leaf; fi
}

# ------------------------------------------------------------------------------------------ render
if [[ $mode == render ]]; then
  [[ -n $sha && -n $repo ]] || die 'render needs --suite-sha and --repo' 2
  is_sha "$sha" || die "--suite-sha must be a lowercase 40-hex commit SHA, got '$sha'"
  render_template "$sha" "$TMP/caller.yml" || {
    case $? in
      3) die "suite commit $sha not found in $suite" ;;
      4) die "templates/ci-gate-caller.yml does not exist at $sha" ;;
      *) die "template at $sha has no __CICD_SUITE_SHA__ placeholder" ;;
    esac
  }
  profile_ok "$sha" "$repo" "$TMP/profile.json" \
    || die "profiles/ci-gate/$repo.json is missing or invalid at $sha; refusing to render a gate that would fail closed"
  [[ ! -f $lock ]] || lock_check_schema   # refuse an untested lock before anything is written
  mkdir -p "$wf_dir" || die "cannot create $wf_dir"
  changes=()
  if [[ -f $caller ]] && cmp -s "$TMP/caller.yml" "$caller"; then
    changes+=("unchanged: $CALLER_REL (pin ${sha:0:12})")
  else
    if ! { cp "$TMP/caller.yml" "$caller.tmp.$$" && mv "$caller.tmp.$$" "$caller"; }; then
      rm -f -- "$caller.tmp.$$"; die "cannot write $caller"
    fi
    changes+=("wrote: $CALLER_REL (pin ${sha:0:12})")
  fi

  mapfile -t guards < <(guard_files)
  if [[ -f $lock ]]; then
    lock_check_schema
    # Retired guard callers: drop their lock entries (deonboard prunes now-unreferenced dependencies).
    while IFS= read -r rel; do
      [[ -n $rel ]] || continue
      bash "$ROOT/scripts/deonboard-workflow.sh" "$checkout" "$rel" >/dev/null
      changes+=("removed lock entry: $rel")
    done < <(retired_lock_keys)
    case $(lock_state) in
      empty) changes+=("unchanged: $LOCK_REL has '$CALLER_REL': []") ;;
      leaf)
        bash "$ROOT/scripts/deonboard-workflow.sh" "$checkout" "$CALLER_REL" >/dev/null
        changes+=("replaced leaf record under $CALLER_REL in $LOCK_REL") ;;
    esac
    if [[ $(lock_state) == absent ]]; then
      # Insert at its sorted position among the existing keys; no other key moves.
      i=0
      while IFS= read -r k; do
        [[ -n $k ]] || continue
        # LC_ALL=C byte order, the order gh actions-lock writes
        [[ $(printf '%s\n%s\n' "$k" "$CALLER_REL" | LC_ALL=C sort | head -1) == "$k" && $k != "$CALLER_REL" ]] && i=$((i+1)) || break
      done < <(yq '.workflows | keys | .[]' "$lock")
      w=$CALLER_REL n=$i yq -i -I4 '
        .workflows = (
          ((.workflows | to_entries) as $e
           | ($e | .[0:(env(n) | tonumber)]) + [{"key": strenv(w), "value": []}] + ($e | .[(env(n) | tonumber):]))
          | from_entries)
        | (.workflows[strenv(w)] | key) style="single"' "$lock"
      changes+=("added '$CALLER_REL': [] to $LOCK_REL")
    fi
    [[ $(lock_state) == empty ]] || die "internal: lock entry for $CALLER_REL is not the empty entry after edit" 1
  else
    changes+=("no $LOCK_REL: lock not touched")
  fi
  for g in "${guards[@]}"; do
    rm -f -- "$g"; changes+=("removed retired guard caller: ${g#"$checkout"/}")
  done
  cc=$checkout/scripts/check-lock-sync.sh; cc_rc=0
  if [[ -f $cc ]]; then
    if [[ $skip_checker -eq 1 ]]; then
      changes+=("SKIPPED consumer lock checker scripts/check-lock-sync.sh (--skip-consumer-checker)")
    else
      cc_out=$(cd "$checkout" && bash scripts/check-lock-sync.sh 2>&1) || cc_rc=$?
      [[ $cc_rc -ne 0 ]] || changes+=("consumer lock checker scripts/check-lock-sync.sh passed")
    fi
  fi
  printf 'ci-gate-caller render %s @ %s\n' "$repo" "$sha"
  printf '  %s\n' "${changes[@]}"
  if [[ $cc_rc -ne 0 ]]; then
    echo "REFUSED consumer-lock-checker: scripts/check-lock-sync.sh exited $cc_rc; the files above were written and are left in place" >&2
    printf '%s\n' "$cc_out" >&2
    exit 1
  fi
  exit 0
fi

# ------------------------------------------------------------------------------------------- check
drift=0
flag() { echo "DRIFT $1: $2"; drift=1; }
mapfile -t guards < <(guard_files)
for g in "${guards[@]}"; do flag guard-caller-leftover "${g#"$checkout"/} still calls the suite's tamper guard"; done

if [[ ! -f $caller ]]; then
  flag caller-missing "$CALLER_REL does not exist"
else
  mapfile -t pins < <(sed -nE "s#^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*['\"]?$SUITE_REPO/\.github/workflows/ci-gate\.yml@([^[:space:]'\"#]+).*#\2#p" "$caller" | sort -u)
  if [[ ${#pins[@]} -eq 0 ]]; then
    flag pin-missing "$CALLER_REL has no 'uses: $SUITE_REPO/.github/workflows/ci-gate.yml@<sha>'"
  elif [[ ${#pins[@]} -gt 1 ]]; then
    flag pin-inconsistent "multiple suite pins: ${pins[*]}"
  elif ! is_sha "${pins[0]}"; then
    flag pin-not-40hex "'${pins[0]}' is not a lowercase 40-hex SHA"
  else
    pin=${pins[0]}
    if render_template "$pin" "$TMP/expected.yml"; then
      cmp -s "$TMP/expected.yml" "$caller" || flag caller-differs "$CALLER_REL differs from templates/ci-gate-caller.yml at its own pin ${pin:0:12}"
    else
      case $? in
        3) flag pin-unknown-to-suite "pin $pin is not a commit in the suite clone $suite" ;;
        *) flag pin-unknown-to-suite "no usable templates/ci-gate-caller.yml at pin $pin" ;;
      esac
    fi
    if [[ -n $repo ]]; then
      profile_ok "$pin" "$repo" "$TMP/profile.json" || flag profile-missing "profiles/ci-gate/$repo.json missing or invalid at pin ${pin:0:12}"
    fi
  fi
fi

if [[ -f $lock ]]; then
  lock_check_schema
  case $(lock_state) in
    absent) flag lock-entry-missing "$LOCK_REL has no '$CALLER_REL' entry (gh actions-lock: not-pinned)" ;;
    leaf)   flag lock-entry-not-empty "$LOCK_REL has a leaf record under '$CALLER_REL'; it must be [] (gh actions-lock: Unused lockfile entry)" ;;
  esac
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    flag lock-extra-entry "$LOCK_REL lists retired guard caller '$k'"
  done < <(retired_lock_keys)
else
  echo "note: no $LOCK_REL; lock checks not run"
fi
[[ -n $repo ]] || echo "note: no --repo; profile check not run"
if [[ $drift -eq 0 ]]; then echo "clean: $checkout"; exit 0; fi
exit 1
