#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Experimental docs-data-v1 subject adapter. Does not certify every link
# or replace the required secret, licence, proof, or governance gates.
# Exit 0: declared local documents checked, no defect observed
# Exit 1: an executed document check found a defect
# Exit 2: NO CHECK WAS PERFORMED (invalid identity, missing tool, unsupported type)
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if (( $# != 3 )) || [[ ! -f $1 || ! -d $2 || ! $3 =~ ^[0-9a-f]{40}$ ]]; then
  echo "VOID: usage: check-docs-data.sh PROFILE.json REPOSITORY_DIR EXPECTED_SHA" >&2
  exit 2
fi
profile=$(realpath -e -- "$1") || exit 2
repo=$(realpath -e -- "$2") || exit 2
sha=$3
for tool in bash jq git realpath mktemp sha256sum lychee; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "VOID: missing executable $tool" >&2
    exit 2
  fi
done

# Tool versions are part of the *experimental canary contract*, not a
# silently floating dependency. A future installer must pin source + digest.
want_lychee="lychee 0.24.2"
got_lychee=$(lychee --version 2>/dev/null) || {
  echo "VOID: cannot execute lychee" >&2; exit 2;
}
if [[ $got_lychee != "$want_lychee" ]]; then
  echo "VOID: lychee version mismatch ($got_lychee; wanted $want_lychee)" >&2
  exit 2
fi

# Identity, tracked-ness, clean source and profile shape must be established
# before interpreting an observed rendering or link failure as subject failure.
if ! bash "$here/check-docs-profile-subject.sh" "$profile" "$repo" "$sha" >/dev/null; then
  echo "VOID: profile/checkout binding not established" >&2
  exit 2
fi

root=$(jq -r '.slots.root' "$profile")
source_root=$(realpath -e -- "$repo/$root") || {
  echo "VOID: document root not found" >&2; exit 2;
}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
count=0
rendered=0

while IFS= read -r relative; do
  if [[ -z $relative ]]; then echo "VOID: empty document entry" >&2; exit 2; fi
  absolute=$(realpath -e -- "$source_root/$relative") || {
    echo "VOID: profile document missing" >&2; exit 2;
  }
  ((count+=1))
  case "$relative" in
    *.adoc|*.asciidoc)
      if ! command -v asciidoctor >/dev/null 2>&1; then
        echo "VOID: asciidoctor missing" >&2; exit 2;
      fi
      version=$(asciidoctor --version | head -n1) || {
        echo "VOID: cannot execute asciidoctor" >&2; exit 2;
      }
      [[ $version == "Asciidoctor 2.0.23"* ]] || {
        echo "VOID: asciidoctor version mismatch" >&2; exit 2;
      }
      # Renderability check is separate from link checking.
      if ! asciidoctor --failure-level WARN -o "$tmp/render-$count.html" "$absolute" >"$tmp/asciidoctor-$count.log" 2>&1; then
        cat "$tmp/asciidoctor-$count.log" >&2
        echo "FIRED: AsciiDoc render failed: $relative" >&2
        exit 1
      fi
      ((rendered+=1))
      ;;
    *.md|*.markdown)
      # lychee recognises Markdown links; this does not establish a complete
      # CommonMark parser conformance claim, only its documented extractor.
      ;;
    *)
      echo "VOID: unsupported document format $relative" >&2
      exit 2
      ;;
  esac

  # Deliberately offline: inspect local links and local anchor references,
  # not the status of remote URLs or mailboxes. No network access requested.
  if ! (cd "$tmp" && lychee --offline --no-progress --root-dir "$repo" "$absolute") >"$tmp/links-$count.log" 2>&1; then
    cat "$tmp/links-$count.log" >&2
    echo "FIRED: local-link checker failed: $relative" >&2
    exit 1
  fi
done < <(jq -r '.slots.documents[]' "$profile")

if (( count == 0 )); then
  echo "VOID: no documents executed" >&2
  exit 2
fi
jq -nc --arg repository "$(jq -r .repository "$profile")" \
       --arg commit "$sha" --arg lychee "$got_lychee" \
       --argjson documents "$count" --argjson rendered "$rendered" \
  '{schema:"proven-cicd/docs-data-observation/v1",repository:$repository,
    commit:$commit, status:"observed-local-doc-checks-passed",
    documents_checked:$documents,asciidoc_rendered:$rendered,
    local_link_checker:"lychee-offline",lychee_version:$lychee,
    excluded_obligations:["remote-URL-availability","full-grammar-exhaustiveness",
                          "secret-scan","spdx-licensing","governance","proof-execution"]}'