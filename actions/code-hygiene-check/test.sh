#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

checker="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check.sh"
readonly checker
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
git -C "$fixture" init -q
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" config user.name 'Hygiene test'
mkdir -p "$fixture/src" "$fixture/docs" "$fixture/.github/workflows" \
  "$fixture/.machine_readable/templates"

printf '%s\n' '// clean source' > "$fixture/src/main.rs"
printf '%s\n' 'TODO in documentation is explanatory.' > "$fixture/docs/design.md"
printf '%s\n' 'example = believe_me value' > "$fixture/docs/example.idr"
printf '%s\n' '// marker in the filename is not debt' > "$fixture/src/TODO.rs"
printf '%s\n' '# TODO: workflow follow-up' > "$fixture/.github/workflows/ci.yml"
printf '%s\n' 'TODO: fill this template' > "$fixture/.machine_readable/templates/example.ncl"
git -C "$fixture" add .
git -C "$fixture" -c commit.gpgsign=false commit -qm fixture

(cd "$fixture" && bash "$checker")

printf '%s\n' '// TODO: TypeScript implementation debt' > "$fixture/src/app.ts"
if (cd "$fixture" && bash "$checker"); then
  echo 'FAIL: untracked TypeScript debt was accepted' >&2
  exit 1
fi
printf '%s\n' '// clean TypeScript source' > "$fixture/src/app.ts"

printf '%s\n' '// TODO: untracked implementation debt' > "$fixture/src/main.rs"
if (cd "$fixture" && bash "$checker"); then
  echo 'FAIL: untracked source debt was accepted' >&2
  exit 1
fi

printf '%s\n' '// TODO(#123): tracked implementation debt' > "$fixture/src/main.rs"
(cd "$fixture" && bash "$checker")

printf '%s\n' 'proof = believe_me value' > "$fixture/src/Safety.idr"
if (cd "$fixture" && bash "$checker"); then
  echo 'FAIL: proof circumvention was accepted' >&2
  exit 1
fi

printf '%s' 'src/Safety.idr' > "$fixture/.cicd-hygiene-allow"
(cd "$fixture" && bash "$checker")
# Only a real Coq proof-hole finding counts as a firing control; an
# unrelated checkout/tool error must not satisfy a negative test.
expect_coq_firing() {
  local label="$1" rc=0
  (cd "$fixture" && bash "$checker" > "$fixture/coq-firing.log" 2>&1) || rc=$?
  if [[ $rc -ne 1 ]] || ! grep -q 'Coq unproved term' "$fixture/coq-firing.log"; then
    echo "FAIL: $label — expected a genuine Coq proof-hole finding" >&2
    cat "$fixture/coq-firing.log" >&2
    exit 1
  fi
  echo "PASS: $label (real proof-hole finding)"
}

# Coq: quoted/commented keywords are not executable proof escapes, while
# Admitted. and the lower-case admit. tactic are real proof holes.
cat > "$fixture/src/CoqProof.v" <<'EOF'
(* SPDX-License-Identifier: MPL-2.0 *)
(* This is a nested (* explanation of Admitted. *) not a proof hole.
   admit. is only a quoted example here. *)
Definition text : string := "Admitted.".
Lemma no_hole : True.
Proof. exact I. Qed.
EOF
(cd "$fixture" && bash "$checker")

cat >> "$fixture/src/CoqProof.v" <<'EOF'
Lemma hole : False.
Proof.
Admitted.
EOF
expect_coq_firing 'executable Coq Admitted. proof hole'
sed -i 's/^Admitted[.]$/admit./' "$fixture/src/CoqProof.v"
expect_coq_firing 'executable Coq admit. tactic'
sed -i 's/^admit[.]$/admit; idtac./' "$fixture/src/CoqProof.v"
expect_coq_firing 'Coq admit tactic composed with a tactical'
sed -i '/^Lemma hole : False[.]$/,$d' "$fixture/src/CoqProof.v"
(cd "$fixture" && bash "$checker")

# Verilog and Coq share the .v suffix. Require an explicit language
# declaration so a hidden Coq proof cannot masquerade as Verilog.
printf '%s\n' 'src/Module.v linguist-language=Verilog' > "$fixture/.gitattributes"
git -C "$fixture" add .gitattributes
cat > "$fixture/src/Module.v" <<'EOF'
module sample;
  // A signal annotation says Admitted. but no Coq proof exists.
  /* Verilog block note: Admitted. is not an executable Coq proof.
     It also says admit; idtac. as prose. */
  initial $display("quote: \\\"");
  wire ready;
endmodule
EOF
(cd "$fixture" && bash "$checker")

# A Coq comment containing quoted delimiters must not hide an executable
# hole; SSReflect // is code, not a Verilog line comment.
cat > "$fixture/src/CoqProof.v" <<'EOF'
(* SPDX-License-Identifier: MPL-2.0 *)
(* "(*" *)
Lemma hole : False. Admitted.
(* "*)" *)
EOF
expect_coq_firing 'Coq quoted comment delimiter cannot hide Admitted.'
cat > "$fixture/src/CoqProof.v" <<'EOF'
(* SPDX-License-Identifier: MPL-2.0 *)
From Coq Require Import ssreflect.
Goal False.
move=> //. Admitted.
EOF
expect_coq_firing 'Coq SSReflect // cannot hide Admitted.'
sed -i 's/^move=> \/\/\. Admitted\.$/move=> \/\/./' "$fixture/src/CoqProof.v"
(cd "$fixture" && bash "$checker")

# Undeclared Verilog-looking files are NOT_RUN until the language is explicit.
printf 'wire ready;\n' > "$fixture/src/Unclassified.v"
git -C "$fixture" add src/Unclassified.v
if (cd "$fixture" && bash "$checker"); then
  echo 'FAIL: undeclared .v language was accepted' >&2
  exit 1
fi
git -C "$fixture" rm -q -f src/Unclassified.v

# Sparse-checkout index entries may be intentionally absent locally.
# Skip only the explicit skip-worktree case; a missing normal file fails.
printf 'Admitted.\n' > "$fixture/src/Sparse.v"
git -C "$fixture" add src/Sparse.v
git -C "$fixture" update-index --skip-worktree src/Sparse.v
rm "$fixture/src/Sparse.v"
(cd "$fixture" && bash "$checker")
printf 'Admitted.\n' > "$fixture/src/Missing.v"
git -C "$fixture" add src/Missing.v
rm "$fixture/src/Missing.v"
if (cd "$fixture" && bash "$checker"); then
  echo 'FAIL: a missing ordinary tracked file was treated as a sparse omission' >&2
  exit 1
fi

coq_scanner="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scan-coq.pl"
rc=0
perl "$coq_scanner" "$fixture/src/missing.v" >/dev/null 2>&1 || rc=$?
if [[ $rc -ne 2 ]]; then
  echo "FAIL: missing Coq source returned $rc instead of NOT_RUN=2" >&2
  exit 1
fi
echo 'Coq/Verilog comments, nested strings, tactics, sparse, missing and NOT_RUN controls passed.'

echo 'All code-hygiene positive and negative controls passed.'
