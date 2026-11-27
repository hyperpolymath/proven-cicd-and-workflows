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
#           x-ratelimit-remaining 0), any 5xx, or no HTTP answer at all, that outlasted the back-off
#           budget. GATE_API_ERR says what. A caller must NOT turn this into a failure verdict.
#           gate_paginate also returns 75 for an INCOMPLETE snapshot (total_count above the items collected).
#     Back-off: Retry-After (seconds or an HTTP-date), else x-ratelimit-reset (only when x-ratelimit-remaining
#     is 0), else 60 s doubling for a secondary rate limit with budget left, else exponential with jitter.
#     Every 5xx is transient, and so is a 2xx whose body was cut off (gh printed 2xx headers but exited
#     non-zero): a GET is retried within the budget, and a write is an UNKNOWN outcome (recheck first).
#     A complete but malformed 2xx body is not transient: it is a real error for the caller.
#     x-ratelimit-reset is an epoch timestamp (ten digits), parsed on its own with room for 12 digits.
#     The total time slept is bounded by CI_GATE_BACKOFF_MAX_SECONDS (default 300; 0 = never wait). The bound is
#     kept in GATE_WAITED (or the file GATE_WAITED_FILE, so a sweep's publishers share one bound).
#     A wait that is already known to overrun the bound is not slept: the call gives up at once.
#
# Test hooks: CI_GATE_SLEEP (the sleep command), CI_GATE_CLOCK (a command that prints epoch
# seconds when called with +%s, default `date`), CI_GATE_JITTER=0 (no jitter).

# shellcheck disable=SC2034  # GATE_API_UNKNOWN and GATE_POST_LOCAL are read by the scripts that source this library
GATE_API_ERR=''
GATE_WAITED=${GATE_WAITED:-0}
# The back-off budget lives in a file so that command substitutions (which run in subshells) share it.
if [[ -z ${GATE_WAITED_FILE:-} ]]; then GATE_WAITED_FILE="${TMPDIR:-/tmp}/ci-gate-waited.$$"; rm -f "$GATE_WAITED_FILE"; fi
GATE_API_RECHECK=()   # set by gate_post only: a command that says whether an unknown-outcome write already landed (exit 0 landed, 1 not landed, 2 cannot tell)
GATE_API_UNKNOWN=0    # sticky for one gate_post: some attempt of the write had an UNKNOWN outcome, so it may have landed
GATE_POST_LOCAL=0     # set by gate_post: it failed on a LOCAL error (no temporary file, unusable description) before any request
GATE_API_PAGES_MAX=50
GATE_SNAPSHOT_CAP=1000   # GitHub lists at most 1000 workflow runs per head_sha and the 1000 most recent check suites
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

# gate__dec <digits> [max digits, default 9] -> the decimal value of a string of digits: leading zeros
# stripped (so 000010 is ten, never octal) and saturated at the largest value of max digits (999999999
# by default), so a hostile header cannot overflow arithmetic. A saturated value is far beyond any
# back-off budget, which is the safe reading of an absurd number. An epoch timestamp (x-ratelimit-reset)
# is ten digits today, so it is parsed with a larger max (12) and never truncated.
gate__dec() {
  local v=$1 max=${2:-9}
  while [[ $v == 0?* ]]; do v=${v#0}; done
  if ((${#v} > max)); then v=$(printf "%${max}s" "" | tr " " 9); fi
  echo $((10#${v:-0}))
}
# gate__date_delay <HTTP-date> -> seconds from now until that date (the HTTP-date form of Retry-After);
# fails for anything that is not one of the three forms RFC 9110 section 5.6.7 has recipients accept,
# all read in the C locale:
#   IMF-fixdate  `Sun, 06 Nov 1994 08:49:37 GMT`
#   RFC 850      `Sunday, 06-Nov-94 08:49:37 GMT` (two-digit year: a year that would be more than 50
#                years ahead of now is read as the most recent past year with those last two digits)
#   asctime      `Sun Nov  6 08:49:37 1994` (the day is space-padded)
gate__date_delay() {
  local d=$1 t now cy y dd mon yy tm
  now=$(gate_now) && [[ $now =~ ^[0-9]+$ ]] || return 1
  if [[ $d =~ ^[A-Za-z]{3},\ [0-9]{2}\ [A-Za-z]{3}\ [0-9]{4}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ GMT$ ]]; then
    t=$(LC_ALL=C date -u -d "$d" +%s 2> /dev/null) || return 1
  elif [[ $d =~ ^(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),\ ([0-9]{2})-([A-Za-z]{3})-([0-9]{2})\ ([0-9]{2}:[0-9]{2}:[0-9]{2})\ GMT$ ]]; then
    dd=${BASH_REMATCH[2]}; mon=${BASH_REMATCH[3]}; yy=${BASH_REMATCH[4]}; tm=${BASH_REMATCH[5]}
    cy=$(LC_ALL=C date -u -d "@$now" +%Y 2> /dev/null) && [[ $cy =~ ^[0-9]{4}$ ]] || return 1
    y=$((cy / 100 * 100 + 10#$yy))
    t=$(LC_ALL=C date -u -d "$dd $mon $y $tm GMT" +%s 2> /dev/null) || return 1
    if [[ $t =~ ^-?[0-9]+$ ]] && ((t > now + 1577880000)); then   # more than 50 years ahead: the past century
      t=$(LC_ALL=C date -u -d "$dd $mon $((y - 100)) $tm GMT" +%s 2> /dev/null) || return 1
    fi
  elif [[ $d =~ ^[A-Za-z]{3}\ ([A-Za-z]{3})\ ([\ 0-9][0-9])\ ([0-9]{2}:[0-9]{2}:[0-9]{2})\ ([0-9]{4})$ ]]; then
    mon=${BASH_REMATCH[1]}; dd=${BASH_REMATCH[2]# }; tm=${BASH_REMATCH[3]}; y=${BASH_REMATCH[4]}
    t=$(LC_ALL=C date -u -d "$dd $mon $y $tm GMT" +%s 2> /dev/null) || return 1
  else
    return 1
  fi
  [[ $t =~ ^-?[0-9]+$ ]] || return 1
  echo $((t - now))
}

gate_api() { # <METHOD> <endpoint> <outfile> [gh api args...]
  local method=$1 ep=$2 out=$3
  shift 3
  local max=${CI_GATE_BACKOFF_MAX_SECONDS:-300} attempt=0 rc rr err0 status kind text ra reset left delay budget known
  [[ $max =~ ^[0-9]+$ ]] || max=300
  [[ ${GATE_API_NOWAIT:-} == 1 ]] && max=0   # a no-wait lookup: one attempt, never a back-off
  while :; do
    : > "$out.raw"
    gh api -i -X "$method" "$ep" "$@" > "$out.raw" 2> "$out.err"
    rc=$?
    # split the "-i" output at the first blank line: status line and headers, then the body
    awk -v h="$out.hdr" -v b="$out" 'BEGIN { inh = 1; printf "" > h; printf "" > b }
      { sub(/\r$/, ""); if (inh) { if ($0 == "") { inh = 0; next } print > h } else print > b }' "$out.raw"
    status=$(sed -n '1s/^HTTP[^ ]* \([0-9][0-9]*\).*/\1/p' "$out.hdr")
    # A WRITE whose 2xx headers arrived was acknowledged by GitHub, whatever happened to the body after
    # that: it landed, so it is neither rechecked nor replayed. (A cut-off GET is retried, below.)
    if ((rc != 0)) && [[ $status =~ ^2 && $method != GET ]]; then
      GATE_API_ERR="HTTP $status on $method ${ep%%\?*}: the body was cut off after 2xx headers; GitHub acknowledged the write, not replayed"
      rm -f "$out.raw"
      return 0
    fi
    if ((rc == 0)) && [[ $status =~ ^2 ]]; then
      rm -f "$out.raw"
      return 0
    fi
    text=$(head -c 2000 "$out" 2> /dev/null; head -c 1000 "$out.err" 2> /dev/null)
    left=$(gate__hdr "$out.hdr" x-ratelimit-remaining)
    kind=error
    case $status in
      429) kind=limit ;;
      403) if grep -qi 'rate limit' <<< "$text" || [[ $left == 0 ]]; then kind=limit; fi ;;
      2[0-9][0-9]) kind=transient ;;   # 2xx headers but a non-zero exit: the body was cut off (unknown outcome of a write)
      5[0-9][0-9]) kind=transient ;;
      '') if ((rc == 4)); then kind=error; else kind=transient; fi ;;   # gh exit 4: no credentials, a real error
    esac
    if [[ $kind == error ]]; then
      GATE_API_ERR="HTTP ${status:-?} on $method ${ep%%\?*}: $(tr '\n' ' ' <<< "$text" | cut -c1-160)"
      rm -f "$out.raw"
      return 1
    fi
    GATE_API_ERR="HTTP ${status:-none} ($kind) on $method ${ep%%\?*}"
    # A 5xx or no answer leaves the OUTCOME of a write unknown. A caller may name a recheck
    # (GATE_API_RECHECK, a command and its arguments): if it says the write is already in place, the
    # request is done and is not replayed. An explicit rate-limit rejection (429, 403) is a known
    # non-write and is never rechecked. A write that ends unknown sets GATE_API_UNKNOWN for good (a later
    # error of the same write must not be read as the first write having been rejected). A recheck that
    # cannot tell (exit 2: its own read failed or came back malformed) is not a licence to replay: the
    # outcome stays unknown and the call returns 75.
    if [[ $kind == transient && $method != GET ]]; then GATE_API_UNKNOWN=1; fi
    if [[ $kind == transient && ${#GATE_API_RECHECK[@]} -gt 0 ]]; then
      err0=$GATE_API_ERR
      "${GATE_API_RECHECK[@]}"; rr=$?
      GATE_API_ERR=$err0   # the recheck is itself a gate_api call and rewrote it
      if ((rr == 0)); then
        GATE_API_ERR="$GATE_API_ERR; a recheck found the write already in place, not replayed"
        rm -f "$out.raw"
        return 0
      elif ((rr == 2)); then
        GATE_API_ERR="$GATE_API_ERR; the recheck could not tell whether the write landed, so it is not replayed (outcome unknown)"
        rm -f "$out.raw"
        return 75
      fi
    fi
    # How long to wait. Retry-After (seconds or an HTTP-date) always wins. A primary rate limit
    # (x-ratelimit-remaining 0) waits until x-ratelimit-reset. A secondary limit (429 or a 403 that says
    # so, with budget left and no Retry-After) starts at 60 s and doubles. Else exponential with jitter.
    known=1; delay=''
    ra=$(gate__hdr "$out.hdr" retry-after)
    reset=$(gate__hdr "$out.hdr" x-ratelimit-reset)
    if [[ $ra =~ ^[0-9]+$ ]]; then
      delay=$(gate__dec "$ra")
    elif [[ -n $ra ]] && delay=$(gate__date_delay "$ra"); then
      :
    elif [[ $kind == limit && $left == 0 && $reset =~ ^[0-9]+$ ]]; then
      delay=$(($(gate__dec "$reset" 12) - $(gate_now) + 1))
    elif [[ $kind == limit && $left != 0 ]]; then
      delay=$((60 << (attempt > 4 ? 4 : attempt)))
    else
      known=0
      delay=$((2 << attempt)); ((delay > 60)) && delay=60
      if [[ ${CI_GATE_JITTER:-} != 0 ]]; then delay=$((delay + RANDOM % (delay / 4 + 1))); fi
    fi
    ((delay < 1)) && delay=1
    budget=$((max - $(gate__waited)))
    # only a guessed (exponential) delay may be shortened to what is left; a delay the server named is
    # never retried early
    if ((known == 0 && delay > budget && budget > 0)); then delay=$budget; fi
    if ((delay > budget || attempt >= 12)); then
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
# Each page must be exactly ONE JSON document of the shape the filter implies (`.key[]`: an object
# whose `key` is an array; `.[]`: an array); a blank, malformed or differently shaped 200 body is an
# error (1, "unusable response body"), while a valid empty page is fine.
# Completeness: a wrapped listing reports `total_count`. If it exceeds the items actually collected
# (GitHub caps `actions/runs?head_sha=` at 1000 results and the commit check-runs listing at the 1000
# most recent check suites) the snapshot is INCOMPLETE and the result is 75 (unavailable, so pending),
# never a verdict: omitted data is never read as a missing check.
# SNAPSHOT listings (the optional 4th argument `runs` or `checks`, set by gate_read_runs and gate_read_checks)
# are held to more: every page must report a numeric `total_count` (a missing or non-numeric one is an unusable
# body, error 1, never read as 0), and because GitHub does not document whether `total_count` counts what lies
# beyond its caps, the snapshot is also INCOMPLETE (75) when it holds 1000 or more workflow runs, or its check
# runs span 1000 or more distinct `check_suite.id` values (the listing covers only the 1000 most recent check
# suites). Both rules are in addition to the total_count comparison, not instead of it.
# Returns gate_api's codes.
gate_paginate() {
  local ep=$1 items=$2 out=$3 snap=${4:-} page=1 sep='?' key='' mode=any total=0 t seen suites
  [[ $ep == *\?* ]] && sep='&'
  if [[ $items == '.[]' ]]; then mode=array
  elif [[ $items =~ ^\.([A-Za-z_]+)\[\]$ ]]; then mode=object; key=${BASH_REMATCH[1]}; fi
  : > "$out.items"
  while :; do
    gate_api GET "${ep}${sep}page=$page" "$out.page" || return $?
    if ! jq -e -s --arg mode "$mode" --arg k "$key" \
      'length == 1 and (.[0] | if $mode == "array" then type == "array" elif $mode == "object" then (type == "object" and (.[$k] | type) == "array") else true end)' \
      "$out.page" > /dev/null 2>&1 \
      || ! jq -c "$items" "$out.page" >> "$out.items" 2> /dev/null; then
      GATE_API_ERR="unusable response body from GET ${ep%%\?*}"
      return 1
    fi
    if [[ -n $snap ]] && ! jq -e 'type == "object" and (.total_count | type) == "number"' "$out.page" > /dev/null 2>&1; then
      GATE_API_ERR="unusable response body from GET ${ep%%\?*}: no numeric total_count"
      return 1
    fi
    t=$(jq -r 'if type == "object" and (.total_count | type) == "number" then .total_count else 0 end' "$out.page" 2> /dev/null) || t=0
    [[ $t =~ ^[0-9]+$ ]] || t=0
    ((t > total)) && total=$t
    if ! gate__hdr "$out.page.hdr" link | grep -q 'rel="next"'; then break; fi
    page=$((page + 1))
    if ((page > GATE_API_PAGES_MAX)); then
      GATE_API_ERR="more than $GATE_API_PAGES_MAX pages from GET ${ep%%\?*}"
      return 1
    fi
  done
  seen=$(grep -c . "$out.items" || true)
  if ((total > seen)); then
    GATE_API_ERR="snapshot incomplete: GET ${ep%%\?*} reports total_count $total but only $seen items were returned (GitHub caps this listing); omitted data is not a missing check"
    return 75
  fi
  if [[ $snap == runs ]] && ((seen >= GATE_SNAPSHOT_CAP)); then
    GATE_API_ERR="snapshot incomplete: GET ${ep%%\?*} returned $seen workflow runs, at or over the cap of $GATE_SNAPSHOT_CAP at which GitHub truncates this listing (its total_count semantics beyond the cap are undocumented); omitted data is not a missing check"
    return 75
  fi
  if [[ $snap == checks ]]; then
    suites=$(jq -s '[.[] | .check_suite.id? // empty] | unique | length' "$out.items" 2> /dev/null) || suites=0
    [[ $suites =~ ^[0-9]+$ ]] || suites=0
    if ((suites >= GATE_SNAPSHOT_CAP)); then
      GATE_API_ERR="snapshot incomplete: GET ${ep%%\?*} spans $suites distinct check suites, at or over the cap of $GATE_SNAPSHOT_CAP most recent suites GitHub lists (its total_count semantics beyond the cap are undocumented); omitted data is not a missing check"
      return 75
    fi
  fi
  jq -s '.' "$out.items" > "$out" || { GATE_API_ERR="unusable items from GET ${ep%%\?*}"; return 1; }
  rm -f "$out.items" "$out.page" "$out.page.hdr" "$out.page.err" "$out.page.raw"
}

# The two reads of one evaluation, however many workflows the commit has.
gate_read_runs() { # <repo> <sha> <outfile> — every workflow run of the head SHA (all pages)
  local repo=$1 sha=$2 out=$3
  gate_paginate "repos/$repo/actions/runs?head_sha=$sha&per_page=100" '.workflow_runs[]' "$out" runs
}
gate_read_checks() { # <repo> <sha> <outfile> — every latest check run of the commit (all pages)
  local repo=$1 sha=$2 out=$3
  gate_paginate "repos/$repo/commits/$sha/check-runs?filter=latest&per_page=100" '.check_runs[]' "$out" checks
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
# Prints "differs" for a valid read that holds no such status, and "unknown" when the read itself failed
# or came back malformed. The dedupe treats unknown like differs (a write is never skipped on doubt); the
# recheck of an unknown-outcome write must NOT (see gate__landed).
gate_status_matches() {
  local repo=$1 sha=$2 ctx=$3 state=$4 desc=$5 f r
  f=$(mktemp) || { echo unknown; return 0; }
  if gate_paginate "repos/$repo/commits/$sha/status?per_page=100" '.statuses[]' "$f"; then
    r=$(jq -r --arg c "$ctx" --arg s "$state" --arg d "$desc" \
      'if type == "array" then (if any(.[]; type == "object" and .context == $c and .state == $s and (.description // "") == $d) then "same" else "differs" end) else "unknown" end' "$f" 2> /dev/null) || r=unknown
  else
    r=unknown
  fi
  rm -f "$f" "$f".*
  echo "$r"
}

# gate__landed <gate_status_matches args> — 0 when the standing status already is the one asked for, 1
# when a valid read says it is not, 2 when the read failed or was malformed (cannot tell: no replay).
# One attempt, no back-off. It runs with the recheck hook cleared so that it cannot recurse into itself.
gate__landed() {
  local -a GATE_API_RECHECK=()
  local r
  r=$(GATE_API_NOWAIT=1 gate_status_matches "$@")
  case $r in same) return 0 ;; differs) return 1 ;; *) return 2 ;; esac
}

# gate_post <repo> <sha> <context> <state> <description> <target_url>
# The one status write: sanitise the description, skip a write that repeats the standing status
# (GitHub keeps at most 1000 statuses per SHA and context), else POST. Returns gate_api's codes
# (0 also when the write was skipped as unchanged). When a POST ends with an UNKNOWN outcome (a 5xx or
# no answer) the standing status is rechecked before the POST is replayed, and a replay is skipped if
# the status is already there; an explicit 429 or 403 rate-limit rejection is retried as before.
# GATE_POST_DEDUPE_NOWAIT=1 makes the first (dedupe) lookup a single attempt with no back-off.
gate_post() {
  local repo=$1 sha=$2 ctx=$3 state=$4 target=$6 desc f rc same
  GATE_API_UNKNOWN=0; GATE_POST_LOCAL=0
  desc=$(gate_sanitize "$5") || { GATE_API_ERR='description could not be sanitised'; GATE_POST_LOCAL=1; return 1; }
  if [[ ${GATE_POST_DEDUPE_NOWAIT:-} == 1 ]]; then
    same=$(GATE_API_NOWAIT=1 gate_status_matches "$repo" "$sha" "$ctx" "$state" "$desc")
  else
    same=$(gate_status_matches "$repo" "$sha" "$ctx" "$state" "$desc")
  fi
  if [[ $same == same ]]; then
    echo "ci-gate: status already $state with this description on $sha; write skipped (1000-status cap)"
    return 0
  fi
  f=$(mktemp) || { GATE_API_ERR='no temporary file'; GATE_POST_LOCAL=1; return 1; }
  GATE_API_RECHECK=(gate__landed "$repo" "$sha" "$ctx" "$state" "$desc")
  gate_api POST "repos/$repo/statuses/$sha" "$f" -f state="$state" -f context="$ctx" -f description="$desc" -f target_url="$target"; rc=$?
  GATE_API_RECHECK=()
  rm -f "$f" "$f".*
  return "$rc"
}

# gate_post_unavailable <repo> <sha> <context> <target_url>
# The one write an unavailable API gets: `pending` with GATE_UNAVAILABLE_DESC, retried with its OWN
# fresh back-off budget (gate_budget_reserve). Never a failure. Its dedupe lookup is a single attempt
# with no back-off, so it cannot spend the reserved budget meant for the write itself; if that lookup
# at once finds the same pending status the write is skipped. Returns gate_post's code.
gate_post_unavailable() {
  local repo=$1 sha=$2 ctx=$3 target=$4
  gate_budget_reserve
  GATE_POST_DEDUPE_NOWAIT=1 gate_post "$repo" "$sha" "$ctx" pending "$GATE_UNAVAILABLE_DESC" "$target"
}
