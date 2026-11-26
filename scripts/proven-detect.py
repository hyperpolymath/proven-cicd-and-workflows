#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""proven-detect: plan the umbrella `proven` gate for one repository.

Reads the repository tree and its manifest (.proven.toml, schema
proven/manifest/v1), and prints a JSON plan:

  { "ok": bool, "errors": [...], "languages": [...], "jobs": [...],
    "waivers": [...], "na": [...], "benches": [...] }

FAIL CLOSED (ER-A8, no pass on absence). `ok` is false, with a named error,
when any of these holds:
  * the manifest is unparseable or has the wrong schema;
  * a source language has no supported runner and no manifest entry for it;
  * a required category has no command (manifest, convention or language
    default) and no N/A reason and no unexpired waiver;
  * a manifest N/A has an empty reason, or a waiver has no reason or expiry,
    or has expired;
  * a manifest names a category this release does not know.

Exit status: 0 plan is ok, 1 plan has errors, 2 could not run.
Usage: proven-detect.py REPO_DIR [--today YYYY-MM-DD] [--categories a,b,c]
"""
from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    print("python >= 3.11 required", file=sys.stderr)
    sys.exit(2)

SCHEMA = "proven/manifest/v1"

# Categories each release enforces. Growing this tuple (and RUNNERS below) is
# how a new category reaches every caller on the next version bump.
SWEEP1 = ("unit", "smoke", "build", "p2p")
KNOWN_CATEGORIES = SWEEP1  # sweep 2+ names are added here as their runners land

# Marker files that declare a language, searched at any depth.
MARKERS = {
    "Cargo.toml": "rust",
    "mix.exs": "elixir",
    "go.mod": "go",
    "deno.json": "deno",
    "deno.jsonc": "deno",
    "package.json": "node",
    "pyproject.toml": "python",
    "setup.py": "python",
    "Project.toml": "julia",
    "build.zig": "zig",
    "dune-project": "ocaml",
    "gleam.toml": "gleam",
    "alire.toml": "ada",
}
SUFFIX_MARKERS = {".ipkg": "idris2", ".gpr": "ada"}

# Source extensions without a marker. A repository with such files and no
# manifest entry fails: an unknown language is never silently skipped.
SOURCE_EXT = {
    ".sh": "shell", ".bash": "shell",
    ".c": "c", ".h": "c", ".cc": "cpp", ".cpp": "cpp", ".hpp": "cpp",
    ".java": "java", ".kt": "kotlin", ".swift": "swift", ".rb": "ruby",
    ".php": "php", ".lua": "lua", ".nim": "nim", ".cr": "crystal",
    ".scala": "scala", ".clj": "clojure", ".erl": "erlang", ".hs": "haskell",
    ".lean": "lean", ".agda": "agda", ".thy": "isabelle", ".tla": "tla",
    ".res": "rescript", ".idr": "idris2", ".v": "coq", ".jl": "julia",
    ".zig": "zig", ".ex": "elixir", ".exs": "elixir", ".gleam": "gleam",
    ".py": "python", ".rs": "rust", ".go": "go", ".ts": "typescript",
    ".js": "javascript", ".mjs": "javascript", ".ml": "ocaml", ".adb": "ada",
    ".ads": "ada", ".nix": "nix",
}
# Languages whose toolchain the umbrella can provision in this release.
PROVISIONED = {"rust", "elixir", "go", "node", "python", "zig", "shell"}
# An extension implies a language already covered by a marker.
EXT_COVERED_BY = {
    "typescript": {"node", "deno"}, "javascript": {"node", "deno"},
    "erlang": {"elixir"}, "idris2": {"idris2"}, "rescript": {"node", "deno"},
}
SKIP_DIRS = {".git", "node_modules", "target", "_build", "deps", "vendor",
             ".venv", "venv", "dist", "build", ".cicd-suite", "zig-cache",
             ".zig-cache", "zig-out", "third_party", "external", "fixtures"}

# Language defaults. A category with no default for a language must come from
# convention (justfile recipe, tests/<category>.sh) or the manifest.
DEFAULTS = {
    "rust": {
        "unit": "cargo test --workspace --lib --bins --locked",
        "build": "cargo build --workspace --all-targets --locked",
        "smoke": "cargo test --workspace --locked --test smoke",
        "p2p": "cargo test --workspace --locked --test p2p",
    },
    "elixir": {
        "unit": "mix test --exclude smoke --exclude p2p",
        "build": "mix compile --warnings-as-errors",
        "smoke": "mix test --only smoke",
        "p2p": "mix test --only p2p",
    },
    "go": {
        "unit": "go test ./...",
        "build": "go build ./...",
        "smoke": "go test -run Smoke ./...",
        "p2p": "go test -run P2P ./...",
    },
    "node": {
        "unit": "npm test",
        "build": "npm run build",
        "smoke": "npm run smoke",
        "p2p": "npm run p2p",
    },
    "python": {
        "unit": "python -m pytest -m 'not smoke and not p2p'",
        "build": "python -m compileall -q .",
        "smoke": "python -m pytest -m smoke",
        "p2p": "python -m pytest -m p2p",
    },
    "zig": {
        "unit": "zig build test",
        "build": "zig build",
    },
    "shell": {},
}
# Which test-suite filename conventions satisfy a category.
CONVENTION_FILES = {
    "unit": ["tests/unit.sh"],
    "smoke": ["tests/smoke.sh"],
    "build": ["tests/build.sh"],
    "p2p": ["tests/p2p.sh"],
}
JUST_RECIPES = {"unit": ("unit", "test"), "smoke": ("smoke",),
                "build": ("build",), "p2p": ("p2p",)}


def die(msg: str, code: int = 2):
    print(f"proven-detect: {msg}", file=sys.stderr)
    sys.exit(code)


def list_files(root: str):
    try:
        out = subprocess.run(["git", "-C", root, "ls-files", "-z"],
                             capture_output=True, check=True).stdout
        files = [f for f in out.decode().split("\0") if f]
        if files:
            return files
    except (OSError, subprocess.CalledProcessError):
        pass
    files = []
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d != ".git"]
        for f in fns:
            files.append(os.path.relpath(os.path.join(dp, f), root))
    return files


def skipped(path: str) -> bool:
    return any(p in SKIP_DIRS for p in path.split("/")[:-1])


def just_recipes(root: str):
    for name in ("justfile", "Justfile", ".justfile"):
        p = os.path.join(root, name)
        if os.path.isfile(p):
            with open(p, encoding="utf-8", errors="replace") as fh:
                return set(re.findall(r"^([A-Za-z0-9_-]+)[^:\n=]*:(?!=)", fh.read(), re.M))
    return set()


def load_manifest(root: str, errors: list):
    p = os.path.join(root, ".proven.toml")
    if not os.path.isfile(p):
        errors.append("manifest-missing: .proven.toml is required (it may be minimal: schema only)")
        return {}
    try:
        with open(p, "rb") as fh:
            m = tomllib.load(fh)
    except (tomllib.TOMLDecodeError, OSError) as e:
        errors.append(f"manifest-unparseable: {e}")
        return {}
    if m.get("schema") != SCHEMA:
        errors.append(f"manifest-schema: schema must be \"{SCHEMA}\", got {m.get('schema')!r}")
    return m


def main():
    args = sys.argv[1:]
    if not args:
        die("usage: proven-detect.py REPO_DIR [--today YYYY-MM-DD]")
    root = args[0]
    today = datetime.date.today()
    cats = list(KNOWN_CATEGORIES)
    i = 1
    while i < len(args):
        if args[i] == "--today":
            today = datetime.date.fromisoformat(args[i + 1]); i += 2
        elif args[i] == "--categories":
            cats = [c for c in args[i + 1].split(",") if c]; i += 2
        else:
            die(f"unknown argument {args[i]}")
    if not os.path.isdir(root):
        die(f"{root} is not a directory")

    errors: list[str] = []
    m = load_manifest(root, errors)
    files = [f for f in list_files(root) if not skipped(f)]

    langs: dict[str, str] = {}  # language -> directory of first marker
    for f in files:
        base = os.path.basename(f)
        lang = MARKERS.get(base)
        if lang is None:
            _, ext = os.path.splitext(base)
            lang = SUFFIX_MARKERS.get(ext)
        if lang:
            langs.setdefault(lang, os.path.dirname(f) or ".")
    ext_langs: set[str] = set()
    for f in files:
        _, ext = os.path.splitext(f)
        lang = SOURCE_EXT.get(ext)
        if lang:
            ext_langs.add(lang)
    ignores = {}
    for ext, v in (m.get("languages", {}).get("ignore", {}) or {}).items():
        if not isinstance(v, dict) or not str(v.get("reason", "")).strip():
            errors.append(f"language-ignore-no-reason: [languages.ignore.{ext}] needs a written reason")
        else:
            ignores[ext] = v["reason"]
    declared = set((m.get("languages", {}).get("declare", []) or []))
    for lang in sorted(ext_langs):
        if lang in langs or lang in declared:
            continue
        if any(c in langs for c in EXT_COVERED_BY.get(lang, ())):
            continue
        if lang == "shell" or lang in PROVISIONED:
            langs.setdefault(lang, ".")
            continue
        # A source language with no marker: only the manifest can account for it.
        if lang in ignores or f".{lang}" in ignores:
            continue
        langs.setdefault(lang, ".")

    cmeta = m.get("categories", {}) or {}
    for name in cmeta:
        if name not in KNOWN_CATEGORIES:
            errors.append(f"category-unknown: [categories.{name}] is not a category this release knows "
                          f"(known: {', '.join(KNOWN_CATEGORIES)}); an unknown name is never ignored")
    recipes = just_recipes(root)
    filenames = set(files)

    jobs, na_list, waivers = [], [], []
    for lang in sorted(langs):
        if lang in ignores:
            continue
        for cat in cats:
            entry = cmeta.get(cat, {}) or {}
            per = entry.get(lang, {}) if isinstance(entry.get(lang), dict) else {}
            na = per.get("na", entry.get("na"))
            if na is not None:
                if not str(na).strip():
                    errors.append(f"na-no-reason: {cat}/{lang} is N/A with an empty reason")
                else:
                    na_list.append({"category": cat, "lang": lang, "reason": na})
                continue
            wv = per.get("waiver", entry.get("waiver"))
            if wv is not None:
                reason = str(wv.get("reason", "")).strip() if isinstance(wv, dict) else ""
                until = wv.get("until") if isinstance(wv, dict) else None
                try:
                    exp = datetime.date.fromisoformat(str(until))
                except ValueError:
                    exp = None
                if not reason or exp is None:
                    errors.append(f"waiver-invalid: {cat}/{lang} waiver needs reason and until=YYYY-MM-DD")
                elif exp < today:
                    errors.append(f"waiver-expired: {cat}/{lang} waiver expired {exp}: {reason}")
                else:
                    waivers.append({"category": cat, "lang": lang, "reason": reason, "until": str(exp)})
                continue
            cmd, source = per.get("command", entry.get("command")), "manifest"
            if cmd is not None and not str(cmd).strip():
                errors.append(f"command-empty: {cat}/{lang} manifest command is empty")
                continue
            if cmd is None:
                for r in JUST_RECIPES[cat]:
                    if r in recipes:
                        cmd, source = f"just {r}", "justfile"
                        break
            if cmd is None:
                for cf in CONVENTION_FILES[cat]:
                    if cf in filenames:
                        cmd, source = f"bash {cf}", "convention"
                        break
            if cmd is None and DEFAULTS.get(lang, {}).get(cat):
                cmd, source = DEFAULTS[lang][cat], "default"
            if cmd is None:
                errors.append(f"missing-runner: {cat}/{lang}: no command (manifest, justfile recipe, "
                              f"tests/{cat}.sh or language default), no N/A reason, no waiver")
                continue
            jobs.append({"id": f"{cat}-{lang}", "category": cat, "lang": lang,
                         "dir": langs[lang], "command": cmd, "source": source})

    benches = []
    for name, b in (m.get("bench", {}) or {}).items():
        if not isinstance(b, dict) or not str(b.get("command", "")).strip():
            errors.append(f"bench-invalid: [bench.{name}] needs a command")
            continue
        benches.append({"name": name, "command": b["command"], "metric": b.get("metric", "seconds"),
                        "lower_is_better": bool(b.get("lower_is_better", True)),
                        "baselining": bool(b.get("baselining", False))})

    plan = {"ok": not errors, "errors": errors, "languages": sorted(langs),
            "jobs": jobs, "waivers": waivers, "na": na_list, "benches": benches,
            "categories": cats}
    json.dump(plan, sys.stdout, indent=2, sort_keys=True)
    print()
    sys.exit(0 if plan["ok"] else 1)


if __name__ == "__main__":
    main()
