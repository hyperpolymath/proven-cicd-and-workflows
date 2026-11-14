#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# build-proven-lock.sh OUT
#
# Builds the proven lock verdict from the generated C this repository ships
# (dist/proven-lock/proven-lock-verdict.c) and the Idris2 RefC runtime vendored
# beside it (dist/proven-lock/runtime/). This repository's CI and consumers
# build it the same way, with no network access.
#
# The runtime is vendored byte for byte from idris-lang/Idris2 at the commit
# that generated the C (owner ruling 2026-11-14; dist/proven-lock/runtime/UPSTREAM
# names the commit, SHA256SUMS lists every file, and
# tests/proven-lock-runtime-vendor.sh checks byte identity with upstream).
# Idris2's BSD-3-Clause LICENSE travels with it, and c/getline.c keeps its own
# NetBSD notice.
#
# Trusted base of the resulting binary, stated so a green is not over-read:
# the two named axioms in src/Proven/Lock/Axioms.idr; the facts decoder and IO
# in src/Proven/Lock/Main.idr (covering, not total, unproven); the extractor
# scripts/extract-lock-facts.sh; the Idris2 compiler that generated the C; the
# vendored RefC runtime; gcc and libgmp.
#
# Exit: 0 built; 2 NOT RUN (missing gcc or gmp.h, missing sources, or the
# compile failed). A build that cannot finish is never a verdict.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
notrun() { printf 'build-proven-lock: %s; NOT RUN\n' "$1" >&2; exit 2; }

out=${1:-}
[[ -n $out && $# -eq 1 ]] || notrun "usage: build-proven-lock.sh OUT"

src=$here/dist/proven-lock/proven-lock-verdict.c
refc=$here/dist/proven-lock/runtime/refc cdir=$here/dist/proven-lock/runtime/c
[[ -f $src ]] || notrun "generated C missing: $src"
compgen -G "$refc/*.c" >/dev/null && compgen -G "$cdir/*.c" >/dev/null ||
  notrun "vendored runtime sources missing under $here/dist/proven-lock/runtime"
command -v gcc >/dev/null || notrun "gcc is not installed"
printf '#include <gmp.h>\n' | gcc -x c -fsyntax-only - 2>/dev/null ||
  notrun "gmp.h not found (install libgmp-dev)"

gcc -O2 -w -I"$refc" -I"$cdir" -o "$out" "$src" "$refc"/*.c "$cdir"/*.c -lgmp -lm ||
  notrun "compile failed"
echo "built $out from $(sha256sum "$src" | cut -c1-16) with the vendored RefC runtime"
