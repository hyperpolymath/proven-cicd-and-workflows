#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Conformance test for proven/manifest.json, the published list of stamped
# artifacts. The applier's read-only BEHIND-CONTENT census token reads this file
# at a pinned SHA of this repository: a stamped copy is BEHIND when its stamp
# names an older version than the manifest does.
#
# The manifest is only worth reading if it agrees with the bodies it describes:
#   * each entry's template starts with exactly the stamp the manifest records,
#     and the template body matches that stamp (scripts/proven-stamp.sh check);
#   * every stamped file under templates/ or .github/workflows/ is listed, and
#     a stamped copy installed here matches its own stamp (no drift) and is
#     never AHEAD of the manifest. It may be BEHIND: refreshing a stale copy is
#     the applier's job (BEHIND-CONTENT, then its content-only rewrite), and
#     this repository's own copy is that rewrite's first canary. A BEHIND copy
#     must be a version that was published: its {version, sha256} is in the
#     artifact's `history`, so a body restamped self-consistently at a lower
#     version is refused;
#   * each artifact's `history` lists every published {version, sha256} in
#     order, ends with the current one, never goes down, and repeats a version
#     only where the earlier entry records the repeat as a `defect`;
#   * artifact names are unique; versions are MAJOR.MINOR.PATCH.
# Then a set of mutants, each run on an isolated copy, must be refused.
# Exit: 0 conforms, 1 broken, 2 not run (no jq, or no manifest).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "proven-manifest: jq missing; NOT RUN" >&2; exit 2; }

# stamp_of FILE: the stamp line, from line 2 (current layout) or line 1 (legacy
# layout, an installed copy that has not been re-stamped); empty when neither.
stamp_of() {
  local l1 l2; l1=$(sed -n 1p "$1"); l2=$(sed -n 2p "$1")
  if [[ $l1 == '# proven-cicd: '* ]]; then printf '%s\n' "$l1"
  elif [[ $l1 == '# SPDX-License-Identifier: '* && $l2 == '# proven-cicd: '* ]]; then printf '%s\n' "$l2"; fi
}

# check DIR: conformance of DIR's manifest against DIR's files. Prints one FAIL
# line per broken rule; returns 0, 1, or 2 when there is nothing to judge.
check() {
  local dir=$1 m=$1/proven/manifest.json fail=0 rows
  [[ -f $m ]] || { echo "NOT RUN: $m missing"; return 2; }
  jq -e '.schema == "proven-cicd/manifest/v1" and (.artifacts | type == "array" and length > 0)' "$m" >/dev/null 2>&1 ||
    { echo "FAIL manifest is not proven-cicd/manifest/v1 with a non-empty artifacts list"; return 1; }
  if ! rows=$(jq -r '.artifacts[] | [.artifact, .version, .sha256, .template, .install_path] |
                     if all(type == "string") then @tsv else error("non-string field") end' "$m" 2>/dev/null); then
    echo "FAIL an artifact entry has a missing or non-string field"; return 1
  fi
  local dups
  local hist
  hist=$(jq -r '.artifacts[] | .artifact as $a | .version as $v | .sha256 as $h |
      if (.history | type) != "array" or (.history | length) == 0 then "\($a)\tno history"
      elif any(.history[]; (type != "object") or ((.version | type) != "string") or ((.sha256 | type) != "string")
               or ((.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) | not) or ((.sha256 | test("^[0-9a-f]{64}$")) | not)
               or ((has("defect") and ((.defect | type) != "string")))) then "\($a)\ta history entry is not {version: MAJOR.MINOR.PATCH, sha256: 64-hex}"
      elif (.history | last) != {version: $v, sha256: $h} and ((.history | last) | del(.defect)) != {version: $v, sha256: $h} then "\($a)\thistory does not end with the current version and sha256"
      elif ([.history[] | [.version, .sha256]] | length) != ([.history[] | [.version, .sha256]] | unique | length) then "\($a)\thistory repeats an entry"
      else empty end' "$m" 2>/dev/null) || { echo "FAIL an artifact history is malformed"; fail=1; }
  [[ -z $hist ]] || { while IFS=$'\t' read -r a why; do echo "FAIL $a: $why"; done <<<"$hist"; fail=1; }
  local order
  order=$(jq -r '.artifacts[] | .artifact as $a | .history as $h | range(1; $h | length) as $i |
      [$a, $h[$i-1].version, $h[$i].version, ($h[$i-1] | has("defect"))] | @tsv' "$m" 2>/dev/null) || true
  local a prev cur flagged
  while IFS=$'\t' read -r a prev cur flagged; do
    [[ -n $a ]] || continue
    if [[ $prev == "$cur" ]]; then
      [[ $flagged == true ]] || { echo "FAIL $a: version $cur names two bodies and the earlier entry records no defect"; fail=1; }
    elif [[ $(printf '%s\n' "$prev" "$cur" | sort -V | tail -n 1) != "$cur" ]]; then
      echo "FAIL $a: history goes down from $prev to $cur"; fail=1
    fi
  done <<<"$order"
  dups=$(cut -f1 <<<"$rows" | sort | uniq -d)
  [[ -z $dups ]] || { echo "FAIL duplicate artifact: $dups"; fail=1; }
  local artifact version sha template install
  while IFS=$'\t' read -r artifact version sha template install; do
    [[ $artifact =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "FAIL artifact name $artifact"; fail=1; }
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL $artifact version $version is not MAJOR.MINOR.PATCH"; fail=1; }
    [[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL $artifact sha256 $sha"; fail=1; }
    [[ $template =~ ^templates/[A-Za-z0-9._-]+\.ya?ml$ && -f $dir/$template ]] ||
      { echo "FAIL $artifact template $template missing or outside templates/"; fail=1; continue; }
    [[ $install =~ ^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$ ]] || { echo "FAIL $artifact install_path $install"; fail=1; }
    local want="# proven-cicd: $artifact@$version sha256:$sha"
    [[ $(sed -n 2p "$dir/$template") == "$want" ]] ||
      { echo "FAIL $template stamp line is not the manifest's: $want"; fail=1; }
    bash "$dir/scripts/proven-stamp.sh" check "$dir/$template" >/dev/null 2>&1 ||
      { echo "FAIL $template body does not match its stamp"; fail=1; }
  done <<<"$rows"
  # Every stamped file here is listed; an installed copy is not ahead.
  local f first name ver
  while IFS= read -r f; do
    first=$(stamp_of "$f")
    name=${first#'# proven-cicd: '}; name=${name%%@*}
    ver=${first#*@}; ver=${ver%% *}
    grep -qxF "$name" <(cut -f1 <<<"$rows") || { echo "FAIL ${f#"$dir/"} names $name, which the manifest does not list"; fail=1; continue; }
    if [[ ${f#"$dir/"} == .github/workflows/* ]]; then
      local want; want=$(awk -F'\t' -v a="$name" '$1 == a { print $2 }' <<<"$rows")
      [[ $(printf '%s\n' "$ver" "$want" | sort -V | tail -n 1) == "$want" ]] ||
        { echo "FAIL ${f#"$dir/"} is $name@$ver, AHEAD of the manifest's $want"; fail=1; }
      bash "$dir/scripts/proven-stamp.sh" check "$f" >/dev/null 2>&1 || { echo "FAIL ${f#"$dir/"} drifted from its stamp"; fail=1; }
      local h=${first##*sha256:}
      jq -e --arg a "$name" --arg v "$ver" --arg h "$h" \
        'any(.artifacts[] | select(.artifact == $a) | .history[]; .version == $v and .sha256 == $h)' "$dir/proven/manifest.json" >/dev/null 2>&1 ||
        { echo "FAIL ${f#"$dir/"} is $name@$ver sha256:${h:0:12}, which was never published (not in history)"; fail=1; }
    fi
  done < <(grep -rlE '^# proven-cicd: ' "$dir/templates" "$dir/.github/workflows" 2>/dev/null |
           while IFS= read -r p; do [[ -n $(stamp_of "$p") ]] && printf '%s\n' "$p"; done)
  return "$fail"
}

set +e
out=$(check "$root"); rc=$?
set -e
[[ -z $out ]] || printf '%s\n' "$out"
case $rc in
  0) echo "ok: proven/manifest.json agrees with every stamped body" ;;
  2) echo "proven-manifest: NOT RUN" >&2; exit 2 ;;
  *) echo "proven-manifest: FAIL" >&2; exit 1 ;;
esac

# Mutants. Each runs on a fresh copy and must be refused with exit 1 (or 2 for
# a missing manifest), never accepted.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fresh() {
  rm -rf -- "$tmp/r"; mkdir -p "$tmp/r/scripts" "$tmp/r/.github"
  cp -R "$root/proven" "$root/templates" "$tmp/r/"
  cp -R "$root/.github/workflows" "$tmp/r/.github/"
  cp "$root/scripts/proven-stamp.sh" "$tmp/r/scripts/"
}
refuse() {
  local name=$1 want=$2 got
  set +e; check "$tmp/r" >"$tmp/out" 2>&1; got=$?; set -e
  if [[ $got != "$want" ]]; then
    echo "FAIL: mutant '$name' gave exit $got, want $want" >&2; cat "$tmp/out" >&2; exit 1
  fi
  echo "ok: refused $name: $(head -n 1 "$tmp/out")"
}
edit_json() {
  local filter=$1
  jq "$filter" "$tmp/r/proven/manifest.json" > "$tmp/m" && mv "$tmp/m" "$tmp/r/proven/manifest.json"
}

fresh; printf '# hand edit\n' >> "$tmp/r/templates/proven-lock-gate.yml"
refuse 'template body edited without restamping' 1
fresh; printf '# hand edit\n' >> "$tmp/r/templates/proven-lock-gate.yml"
bash "$tmp/r/scripts/proven-stamp.sh" stamp "$tmp/r/templates/proven-lock-gate.yml" >/dev/null
refuse 'template restamped but manifest hash not updated' 1
fresh; edit_json '.artifacts[0].version = "0.4.0"'
refuse 'manifest version ahead of the template stamp' 1
fresh; edit_json '.artifacts[0].sha256 = ("0" * 64)'
refuse 'manifest hash for another body' 1
fresh; edit_json '.artifacts += [.artifacts[0]]'
refuse 'duplicate artifact' 1
fresh; edit_json '.artifacts[0].version = "0.1"'
refuse 'version not MAJOR.MINOR.PATCH' 1
fresh; edit_json 'del(.artifacts[0].install_path)'
refuse 'missing field' 1
fresh; edit_json '.artifacts = []'
refuse 'empty artifacts list' 1
fresh; sed '2s/proven-lock-gate@/unlisted-gate@/' "$tmp/r/templates/proven-lock-gate.yml" > "$tmp/r/templates/unlisted.yml"
refuse 'stamped template the manifest does not list' 1
fresh; sed -i '1s/@0\.1\.0 /@9.9.9 /' "$tmp/r/.github/workflows/proven-lock-gate.yml"
refuse 'installed copy AHEAD of the manifest' 1
fresh; printf '# hand edit\n' >> "$tmp/r/.github/workflows/proven-lock-gate.yml"
refuse 'installed copy drifted from its stamp' 1
fresh; w=$tmp/r/.github/workflows/proven-lock-gate.yml
# The installed copy is in the legacy layout; stamp writes only the current one.
{ sed -n 2p "$w"; sed -n 1p "$w" | sed 's/@0\.1\.0 /@0.0.9 /'; tail -n +3 "$w"; } > "$tmp/w" && mv "$tmp/w" "$w"
bash "$tmp/r/scripts/proven-stamp.sh" stamp "$tmp/r/.github/workflows/proven-lock-gate.yml" >/dev/null
refuse 'installed copy restamped at a version that was never published' 1
fresh; edit_json '(.artifacts[0].history) |= .[:-1]'
refuse 'history that does not end with the current version' 1
fresh; edit_json '(.artifacts[0].history) |= [.[1], .[0]] + .[2:]'
refuse 'history that goes down' 1
fresh; edit_json '(.artifacts[0].history) |= [.[0], (.[0] | .sha256 = ("1" * 64))] + .[1:]'
refuse 'a version naming two bodies with no recorded defect' 1
fresh; edit_json 'del(.artifacts[0].history)'
refuse 'missing history' 1
fresh; edit_json '.artifacts[0].history[1].sha256 = "not-a-sha"'
refuse 'a middle history entry with a malformed sha256' 1
fresh; edit_json '.artifacts[0].history[0].version = "0.1"'
refuse 'a middle history entry with a malformed version' 1
fresh; rm "$tmp/r/proven/manifest.json"
refuse 'manifest missing' 2
echo "proven-manifest: manifest conforms (installed copy may lag, to a published version); 19 mutants refused"
