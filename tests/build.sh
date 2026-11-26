#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# build: every script parses, the proven-gate crate compiles, and every
# workflow and the manifest parse (the gate itself checks them). (The Idris2
# kernels build in assurance-kernel.yml.)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail=0
for f in $(git ls-files 'scripts/*.sh' 'tests/*.sh' 'actions/**/*.sh' 'templates/*.sh' '*.sh'); do bash -n "$f" || { echo "build: $f does not parse"; fail=1; }; done
cargo build --locked --quiet --manifest-path tools/proven-gate/Cargo.toml || { echo "build: proven-gate does not compile"; fail=1; }
GATE=$(bash scripts/proven-gate-bin.sh) || { echo "build: proven-gate binary unavailable"; exit 1; }
"$GATE" integrity .github/workflows/proven-self.yml >/dev/null || { echo "build: workflows or caller do not parse"; fail=1; }
"$GATE" detect . >/dev/null || { echo "build: manifest does not parse or plan fails"; fail=1; }
(( fail == 0 )) && echo "build: ok"; exit "$fail"
