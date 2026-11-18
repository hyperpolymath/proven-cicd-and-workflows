#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# ci-gate-lib.sh — the one place the interim CI/gate talks to GitHub and writes a status.
# Sourced (never executed) by scripts/ci-gate-publish.sh, scripts/ci-gate-sweep.sh and the
# reusable workflow's later steps. It uses only `gh` and `jq` on PATH, so a stub can drive it.
#
# EVERY API call goes through gate_api (the single bootstrap fetch of this file by the reusable
# is the one unavoidable exception, because this file cannot fetch itself). EVERY status
# description goes through gate_sanitize (inside gate_post).
#
#   gate_api METHOD ENDPOINT OUTFILE [gh api args...]
#       0   2xx; the body is in OUTFILE, the response headers in OUTFILE.hdr
#       1   a real error (a 4xx that is not a rate limit, a 403 that is a permissions problem, an
#           unusable body): GATE_API_ERR says what. NEVER retried.
#       75  unavailable: a rate limit (HTTP 429, or 403 with "rate limit" in the body or
#           x-ratelimit-remaining 0), a 5xx, or no HTTP answer at all, that outlasted the back-off
#           budget. GATE_API_ERR says what. A caller must NOT turn this into a failure verdict.
#     Back-off: Retry-After, else x-ratelimit-reset, else exponential with jitter. The total time
#     slept is bounded by CI_GATE_BACKOFF_MAX_SECONDS (default 300; 0 = never wait). The bound is
#     kept in GATE_WAITED (or the file GATE_WAITED_FILE, so a sweep's publishers share one bound).
#     A wait that is already known to overrun the bound is not slept: the call gives up at once.
#
# Test hooks: CI_GATE_SLEEP (the sleep command), CI_GATE_CLOCK (a command that prints epoch
# seconds when called with +%s, default `date`), CI_GATE_JITTER=0 (no jitter).

GATE_API_ERR=''
GATE_WAITED=${GATE_WAITED:-0}
# The back-off budget lives in a file so that command substitutions (which run in subshells) share it.
if [[ -z ${GATE_WAITED_FILE:-} ]]; then GATE_WAITED_FILE="${TMPDIR:-/tmp}/ci-gate-waited.$$"; rm -f "$GATE_WAITED_FILE"; fi
GATE_API_PAGES_MAX=50
GATE_UNAVAILABLE_DESC='ci-gate: GitHub API rate-limited or unavailable; re-evaluating later'

gate_now() { "${CI_GATE_CLOCK:-date}" +%s; }
gate_sleep() { "${CI_GATE_SLEEP:-sleep}" "$1"; }

# gate_sanitize <text> — the only description sanitiser. The statuses API rejects characters above
# U+FFFF ("Description doesn't accept 4-byte Unicode") and anything over 140 characters. This drops
# every codepoint above U+FFFF (and lone surrogates), then, when more than 140 codepoints remain,
# keeps the first 139 and appends an ellipsis, cutting between codepoints, never inside one.
gate_sanitize() {
  jq -rn --arg d "$1" '
    $d | explode
    | map(select(. <= 65535 and (. < 55296 or . > 57343)))
    | if length > 140 then .[0:139] + [8230] else . end
    | implode'
}

gate__waited() {
  local v=${GATE_WAITED:-0}
  [[ -n ${GATE_WAITED_FILE:-} && -f $GATE_WAITED_FILE ]] && v=$(cat "$GATE_WAITED_FILE")
  [[ $v =~ ^[0-9]+$ ]] || v=0
  echo "$v"
}
gate__add_waited() {
  GATE_WAITED=$(($(gate__waited) + $1))
  if [[ -n ${GATE_WAITED_FILE:-} ]]; then echo "$GATE_WAITED" > "$GATE_WAITED_FILE"; fi
}
# gate_budget_reserve — a fresh, separate back-off budget for the one final pending write after the
# reads gave up, so a persistent rate limit cannot also starve that write. Total wait of one process
# is therefore at most twice CI_GATE_BACKOFF_MAX_SECONDS.
gate_budget_reserve() {
  GATE_WAITED=0
  if [[ -n ${GATE_WAITED_FILE:-} ]]; then GATE_WAITED_FILE="${GATE_WAITED_FILE%.reserve}.reserve"; rm -f "$GATE_WAITED_FILE"; fi
}

gate__hdr() { # <header file> <name> -> the value of the first such header, case-insensitive
  awk -v n="$2" 'BEGIN { n = tolower(n) }
    { i = index($0, ":"); if (i > 0 && tolower(substr($0, 1, i - 1)) == n) { v = substr($0, i + 1); gsub(/^[ \t]+|[ \t\r]+$/, "", v); print v; exit } }' "$1"
}

gate_api() { # <METHOD> <endpoint> <outfile> [gh api args...]
  local method=$1 ep=$2 out=$3
  shift 3
  local max=${CI_GATE_BACKOFF_MAX_SECONDS:-300} attempt=0 rc status kind text ra reset delay remaining known
  [[ $max =~ ^[0-9]+$ ]] || max=300
  while :; do
    : > "$out.raw"
    gh api -i -X "$method" "$ep" "$@" > "$out.raw" 2> "$out.err"
    rc=$?
    # split the "-i" output at the first blank line: status line and headers, then the body
    awk -v h="$out.hdr" -v b="$out" 'BEGIN { inh = 1; printf "" > h; printf "" > b }
      { sub(/\r$/, ""); if (inh) { if ($0 == "") { inh = 0; next } print > h } else print > b }' "$out.raw"
    status=$(sed -n '1s/^HTTP[^ ]* \([0-9][0-9]*\).*/\1/p' "$out.hdr")
    if ((rc == 0)) && [[ $status =~ ^2 ]]; then
      rm -f "$out.raw"
      return 0
    fi
    text=$(head -c 2000 "$out" 2> /dev/null; head -c 1000 "$out.err" 2> /dev/null)
    kind=error
    case $status in
      429) kind=limit ;;
      403) if grep -qi 'rate limit' <<< "$text" || [[ $(gate__hdr "$out.hdr" x-ratelimit-remaining) == 0 ]]; then kind=limit; fi ;;
      500 | 502 | 503 | 504) kind=transient ;;
      '') if ((rc == 4)); then kind=error; else kind=transient; fi ;;   # gh exit 4: no credentials, a real error
    esac
    if [[ $kind == error ]]; then
      GATE_API_ERR="HTTP ${status:-?} on $method ${ep%%\?*}: $(tr '\n' ' ' <<< "$text" | cut -c1-160)"
      rm -f "$out.raw"
      return 1
    fi
    GATE_API_ERR="HTTP ${status:-none} ($kind) on $method ${ep%%\?*}"
    # How long to wait: Retry-After, else x-ratelimit-reset (a rate limit only), else exponential + jitter.
    known=1
    ra=$(gate__hdr "$out.hdr" retry-after)
    reset=$(gate__hdr "$out.hdr" x-ratelimit-reset)
    if [[ $ra =~ ^[0-9]+$ ]]; then
      delay=$ra
    elif [[ $kind == limit && $reset =~ ^[0-9]+$ ]]; then
      delay=$((reset - $(gate_now) + 1))
    else
      known=0
      delay=$((2 << attempt)); ((delay > 60)) && delay=60
      if [[ ${CI_GATE_JITTER:-} != 0 ]]; then delay=$((delay + RANDOM % (delay / 4 + 1))); fi
    fi
    ((delay < 1)) && delay=1
    remaining=$((max - $(gate__waited)))
    if ((known == 0 && delay > remaining && remaining > 0)); then delay=$remaining; fi
    if ((delay > remaining || attempt >= 12)); then
      GATE_API_ERR="$GATE_API_ERR; gave up: waiting ${delay}s would exceed the ${max}s back-off bound"
      rm -f "$out.raw"
      return 75
    fi
    echo "ci-gate: GitHub API throttled or unavailable ($GATE_API_ERR); waiting ${delay}s ($(($(gate__waited) + delay)) of ${max}s used)" >&2
    gate_sleep "$delay"
    gate__add_waited "$delay"
    attempt=$((attempt + 1))
  done
}

# gate_paginate <endpoint> <jq filter producing the items of one page> <outfile>
# Follows the Link header (rel="next") with page=N. OUTFILE holds ONE JSON array of every item.
# Returns gate_api's codes; an unusable body is 1.
gate_paginate() {
  local ep=$1 items=$2 out=$3 page=1 sep='?'
  [[ $ep == *\?* ]] && sep='&'
  : > "$out.items"
  while :; do
    gate_api GET "${ep}${sep}page=$page" "$out.page" || return $?
    if ! jq -c "$items" "$out.page" >> "$out.items" 2> /dev/null; then
      GATE_API_ERR="unusable response body from GET ${ep%%\?*}"
      return 1
    fi
    if ! gate__hdr "$out.page.hdr" link | grep -q 'rel="next"'; then break; fi
    page=$((page + 1))
    if ((page > GATE_API_PAGES_MAX)); then
      GATE_API_ERR="more than $GATE_API_PAGES_MAX pages from GET ${ep%%\?*}"
      return 1
    fi
  done
  jq -s '.' "$out.items" > "$out" || { GATE_API_ERR="unusable items from GET ${ep%%\?*}"; return 1; }
  rm -f "$out.items" "$out.page" "$out.page.hdr" "$out.page.err" "$out.page.raw"
}

# The two reads of one evaluation, however many workflows the commit has.
gate_read_runs() { # <repo> <sha> <outfile> — every workflow run of the head SHA (all pages)
  gate_paginate "repos/$1/actions/runs?head_sha=$2&per_page=100" '.workflow_runs[]' "$3"
}
gate_read_checks() { # <repo> <sha> <outfile> — every latest check run of the commit (all pages)
  gate_paginate "repos/$1/commits/$2/check-runs?filter=latest&per_page=100" '.check_runs[]' "$3"
}
# gate_read_snapshot <repo> <sha> <dir> <join.jq>
#   -> <dir>/workflow-runs.json, <dir>/check-runs.json and <dir>/jobs.json (the check runs joined to
#   their workflow run on check_suite id). Two logical reads, so 2 requests for a commit with fewer than
#   100 runs and fewer than 100 check runs, plus one request per further page.
gate_read_snapshot() {
  local repo=$1 sha=$2 dir=$3 join=$4 rc
  gate_read_runs "$repo" "$sha" "$dir/workflow-runs.json"; rc=$?
  ((rc == 0)) || return "$rc"
  gate_read_checks "$repo" "$sha" "$dir/check-runs.json"; rc=$?
  ((rc == 0)) || return "$rc"
  jq -n --slurpfile runs "$dir/workflow-runs.json" --slurpfile checks "$dir/check-runs.json" -f "$join" > "$dir/jobs.json.new" \
    || { GATE_API_ERR='the runs and check runs could not be joined (malformed data)'; return 1; }
  mv "$dir/jobs.json.new" "$dir/jobs.json"
}

# gate_fetch <repo> <path> <ref> <dest> — one file of a repository, raw; refuses an empty file.
gate_fetch() {
  local rc
  gate_api GET "repos/$1/contents/$2?ref=$3" "$4.tmp" -H 'Accept: application/vnd.github.raw+json'; rc=$?
  if ((rc == 0)); then
    if [[ -s $4.tmp ]]; then mv "$4.tmp" "$4"; else GATE_API_ERR="$2 at $1@$3 is empty"; rc=1; fi
  fi
  rm -f "$4.tmp" "$4.tmp.hdr" "$4.tmp.err" "$4.tmp.raw"
  return "$rc"
}

# gate_status_matches <repo> <sha> <context> <state> <description-already-sanitised>
# Prints "same" only if the combined status of the commit already holds exactly this for the context.
# A failed or malformed read prints "differs": a write is never skipped on doubt.
gate_status_matches() {
  local f r
  f=$(mktemp) || { echo differs; return 0; }
  if gate_paginate "repos/$1/commits/$2/status?per_page=100" '.statuses[]' "$f"; then
    r=$(jq -r --arg c "$3" --arg s "$4" --arg d "$5" \
      'if type == "array" and any(.[]; type == "object" and .context == $c and .state == $s and (.description // "") == $d) then "same" else "differs" end' "$f" 2> /dev/null) || r=differs
  else
    r=differs
  fi
  rm -f "$f" "$f".*
  echo "$r"
}

# gate_post <repo> <sha> <context> <state> <description> <target_url>
# The one status write: sanitise the description, skip a write that repeats the standing status
# (GitHub keeps at most 1000 statuses per SHA and context), else POST. Returns gate_api's codes
# (0 also when the write was skipped as unchanged).
gate_post() {
  local desc f rc
  desc=$(gate_sanitize "$5") || { GATE_API_ERR='description could not be sanitised'; return 1; }
  if [[ $(gate_status_matches "$1" "$2" "$3" "$4" "$desc") == same ]]; then
    echo "ci-gate: status already $4 with this description on $2; write skipped (1000-status cap)"
    return 0
  fi
  f=$(mktemp) || { GATE_API_ERR='no temporary file'; return 1; }
  gate_api POST "repos/$1/statuses/$2" "$f" -f state="$4" -f context="$3" -f description="$desc" -f target_url="$6"; rc=$?
  rm -f "$f" "$f".*
  return "$rc"
}

# gate_post_unavailable <repo> <sha> <context> <target_url>
# The one write an unavailable API gets: `pending` with GATE_UNAVAILABLE_DESC, retried with its OWN
# fresh back-off budget (gate_budget_reserve). Never a failure. Returns gate_post's code.
gate_post_unavailable() {
  gate_budget_reserve
  gate_post "$1" "$2" "$3" pending "$GATE_UNAVAILABLE_DESC" "$4"
}
