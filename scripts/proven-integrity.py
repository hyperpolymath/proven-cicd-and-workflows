#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""ER-A8 workflow integrity: no pass on absence.

proven-integrity.py CALLER_WORKFLOW_PATH   (repository root: $PROVEN_ROOT or cwd)
A missing, skipped or unparseable workflow fails. Exit 0 ok, 1 defect, 2 could not run.
"""
import glob, os, re, sys
try:
    import yaml
except ModuleNotFoundError:
    print("::error::PyYAML unavailable; integrity NOT CHECKED"); sys.exit(2)

root = os.path.realpath(os.environ.get("PROVEN_ROOT") or os.getcwd())
os.chdir(root)
caller = os.path.realpath(os.path.join(root, sys.argv[1]))
if not caller.startswith(root + os.sep):
    print("::error::caller workflow path escapes the repository"); sys.exit(2)
caller = os.path.relpath(caller, root)
bad = []
def err(m): bad.append(m); print(f"::error::ER-A8: {m}")

def load(p):
    try:
        with open(p, encoding="utf-8") as fh:
            d = yaml.safe_load(fh)
        return d if isinstance(d, dict) else None
    except Exception:
        return None

files = sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml"))
if not files:
    err("no workflow files under .github/workflows")
for f in files:
    d = load(f)
    if d is None or not isinstance(d.get("jobs"), dict) or not d["jobs"]:
        err(f"{f} is unparseable or has no jobs")
if not os.path.isfile(".github/workflows/proven-lock-gate.yml"):
    err("stamped .github/workflows/proven-lock-gate.yml is missing (SR-005)")

pat = re.compile(r"(^\./\.github/workflows/proven\.yml$)|(/\.github/workflows/proven\.yml@)")
d = load(caller) if os.path.isfile(caller) else None
if d is None:
    err(f"caller workflow {caller} is missing or unparseable")
else:
    on = d.get("on", d.get(True))  # YAML 1.1 parses a bare `on` key as True
    trig = set(on) if isinstance(on, (dict, list)) else {on}
    jobs = {k: v for k, v in d["jobs"].items() if isinstance(v, dict) and pat.search(str(v.get("uses", "")))}
    if not jobs:
        err(f"{caller} has no job calling the proven umbrella workflow")
    for k, v in jobs.items():
        if k != "proven":
            err(f"{caller}: the umbrella job id must be 'proven' (required check 'proven / verdict'), found '{k}'")
        if "if" in v:
            err(f"{caller}: job '{k}' has an 'if:'; a skipped gate is not a pass")
        if "continue-on-error" in v:
            err(f"{caller}: job '{k}' sets continue-on-error")
        if not trig & {"pull_request", "merge_group"}:
            err(f"{caller} is not triggered by pull_request or merge_group")
for f in glob.glob(".github/workflows/proven*.yml"):
    if re.search(r"^\s*continue-on-error:\s*true", open(f, encoding="utf-8").read(), re.M):
        err(f"{f} sets continue-on-error: true")
if not bad:
    print(f"ER-A8 integrity: ok ({len(files)} workflow files)")
sys.exit(1 if bad else 0)
