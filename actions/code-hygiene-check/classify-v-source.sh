#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Classify ambiguous .v inputs before any Coq-specific lexical scan.
# Exit 0 with coq/verilog; exit 2 when classification cannot be trusted.
# Call from the repository root, with a tracked/untracked relative path.
set -euo pipefail
file="${1:-}"
if [[ "$file" != *.v || ! -r "$file" ]]; then
  echo "NOT_RUN: expected a readable .v input: $file" >&2
  exit 2
fi

# Explicit GitHub Linguist metadata is the strongest declaration.
attr="$(git check-attr linguist-language -- "$file" | sed -n 's/^.*: linguist-language: //p')"
declared=''
case "$attr" in
  Coq|Rocq) declared=coq ;;
  Verilog|'SystemVerilog') declared=verilog ;;
  'unspecified'|'unset'|'') ;;
  *) echo "NOT_RUN: unknown .v language attribute '$attr' in $file" >&2; exit 2 ;;
esac

# Do not silently treat Verilog syntax as Coq or vice versa. These source
# cues are intentionally narrow; unclear or conflicting inputs need a
# declared linguist-language in .gitattributes and a real language checker.
coq=0
verilog=0
if grep -Eq '^[[:space:]]*(From[[:space:]].*[[:space:]]Require|Require[[:space:]]+Import|Lemma[[:space:]]|Theorem[[:space:]]|Corollary[[:space:]]|Definition[[:space:]]|Inductive[[:space:]]|Fixpoint[[:space:]]|Goal[[:space:]]|Proof[.]?|Qed[.]|Admitted[.])' "$file"; then coq=1; fi
if grep -Eq '^[[:space:]]*(module[[:space:]]|endmodule\b|primitive[[:space:]]|endprimitive\b|wire[[:space:]]|reg[[:space:]]|assign[[:space:]]|always(@|\b)|interface[[:space:]]|endinterface\b)' "$file"; then verilog=1; fi

# Untrusted prose can contain a language cue. Contradictions fail closed.
if [[ "$coq" -eq 1 && "$verilog" -eq 1 ]]; then
  echo "NOT_RUN: mixed Coq/Verilog language cues in $file" >&2
  exit 2
fi
if [[ "$declared" = coq && "$verilog" -eq 1 ]] ||
   [[ "$declared" = verilog && "$coq" -eq 1 ]]; then
  echo "NOT_RUN: .v language attribute conflicts with source in $file" >&2
  exit 2
fi
if [[ -n "$declared" ]]; then
  printf '%s\n' "$declared"
elif [[ "$coq" -eq 1 ]]; then
  echo coq
elif [[ "$verilog" -eq 1 ]]; then
  echo "NOT_RUN: Verilog source requires explicit linguist-language=Verilog in .gitattributes: $file" >&2
  exit 2
else
  echo "NOT_RUN: cannot classify .v language in $file; declare linguist-language" >&2
  exit 2
fi
