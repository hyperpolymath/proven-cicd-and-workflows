#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Six Sigma bench gate (TESTING-TAXONOMY Part IV).

proven-bench-gate.py CURRENT --history v1,v2,... [--higher-is-better] [--baselining]

Baseline = mean of the last 10 history values (main runs). Worse-than-baseline
percentage drives the class:
  Unacceptable   > 50% worse   exit 1 (blocks)
  Acceptable     20..50% worse exit 3 (needs reviewer approval: fails the check
                               until a reviewer applies the approve label)
  Ordinary       within 20%    exit 0
  Extraordinary  > 20% better  exit 0 (flag)
No history is an error (exit 2) unless --baselining, which records and passes.
"""
import argparse, json, sys

ap = argparse.ArgumentParser()
ap.add_argument("current", type=float)
ap.add_argument("--history", default="")
ap.add_argument("--higher-is-better", action="store_true")
ap.add_argument("--baselining", action="store_true")
a = ap.parse_args()
hist = [float(x) for x in a.history.split(",") if x.strip()][-10:]
if not hist:
    if a.baselining:
        print(json.dumps({"class": "Baselining", "baseline": None, "current": a.current}))
        sys.exit(0)
    print(json.dumps({"class": "NoBaseline", "current": a.current}))
    print("no history on main and [bench.*] baselining is not set: no pass on absence", file=sys.stderr)
    sys.exit(2)
base = sum(hist) / len(hist)
if base == 0:
    print(json.dumps({"class": "NoBaseline", "baseline": 0}))
    sys.exit(2)
worse = (base - a.current) / base if a.higher_is_better else (a.current - base) / base
pct = round(worse * 100, 2)
if worse > 0.50: cls, rc = "Unacceptable", 1
elif worse >= 0.20: cls, rc = "Acceptable", 3
elif worse < -0.20: cls, rc = "Extraordinary", 0
else: cls, rc = "Ordinary", 0
print(json.dumps({"class": cls, "baseline": base, "current": a.current, "worse_pct": pct, "n": len(hist)}))
sys.exit(rc)
