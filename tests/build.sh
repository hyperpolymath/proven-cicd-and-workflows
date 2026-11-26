#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# build: every script parses, every workflow and manifest parses, the
# python tools compile. (The Idris2 kernels build in assurance-kernel.yml.)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail=0
for f in $(git ls-files 'scripts/*.sh' 'tests/*.sh' 'actions/**/*.sh' 'templates/*.sh' '*.sh'); do bash -n "$f" || { echo "build: $f does not parse"; fail=1; }; done
python3 -m py_compile scripts/*.py || fail=1
python3 - <<'PY' || fail=1
import glob, sys, yaml, tomllib
bad = 0
for f in glob.glob(".github/workflows/*.yml") + glob.glob("templates/*.yml"):
    try: yaml.safe_load(open(f))
    except Exception as e: print(f"build: {f}: {e}"); bad = 1
tomllib.load(open(".proven.toml", "rb"))
sys.exit(bad)
PY
(( fail == 0 )) && echo "build: ok"; exit "$fail"
