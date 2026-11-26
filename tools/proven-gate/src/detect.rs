// SPDX-License-Identifier: MPL-2.0
//! Plan the umbrella `proven` gate for one repository.
//!
//! Reads the tree and the manifest (.proven.toml, schema proven/manifest/v1)
//! and prints a JSON plan. FAIL CLOSED (ER-A8): `ok` is false, with a named
//! error, for an unparseable or wrong-schema manifest, a source language with
//! no runner and no manifest entry, a category with no command and no N/A
//! reason and no unexpired waiver, an empty reason, an invalid or expired
//! waiver, or a category this release does not know.
//!
//! Exit: 0 plan ok, 1 plan has errors, 2 could not run.

use crate::date::{self, Date};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;
use toml::{Table, Value as T};

const SCHEMA: &str = "proven/manifest/v1";
// Growing this list (and the runners) is how a category reaches every caller on a bump.
const KNOWN_CATEGORIES: [&str; 4] = ["unit", "smoke", "build", "p2p"];

const SKIP_DIRS: [&str; 16] = [
    ".git", "node_modules", "target", "_build", "deps", "vendor", ".venv", "venv", "dist", "build",
    ".cicd-suite", "zig-cache", ".zig-cache", "zig-out", "third_party", "external",
];

fn is_skipped_dir(name: &str) -> bool {
    name == "fixtures" || SKIP_DIRS.contains(&name)
}

fn marker(base: &str) -> Option<&'static str> {
    Some(match base {
        "Cargo.toml" => "rust",
        "mix.exs" => "elixir",
        "go.mod" => "go",
        "deno.json" | "deno.jsonc" => "deno",
        "package.json" => "node",
        "pyproject.toml" | "setup.py" => "python",
        "Project.toml" => "julia",
        "build.zig" => "zig",
        "dune-project" => "ocaml",
        "gleam.toml" => "gleam",
        "alire.toml" => "ada",
        _ => return None,
    })
}

fn suffix_marker(ext: &str) -> Option<&'static str> {
    match ext {
        ".ipkg" => Some("idris2"),
        ".gpr" => Some("ada"),
        _ => None,
    }
}

fn source_lang(ext: &str) -> Option<&'static str> {
    Some(match ext {
        ".sh" | ".bash" => "shell",
        ".c" | ".h" => "c",
        ".cc" | ".cpp" | ".hpp" => "cpp",
        ".java" => "java",
        ".kt" => "kotlin",
        ".swift" => "swift",
        ".rb" => "ruby",
        ".php" => "php",
        ".lua" => "lua",
        ".nim" => "nim",
        ".cr" => "crystal",
        ".scala" => "scala",
        ".clj" => "clojure",
        ".erl" => "erlang",
        ".hs" => "haskell",
        ".lean" => "lean",
        ".agda" => "agda",
        ".thy" => "isabelle",
        ".tla" => "tla",
        ".res" => "rescript",
        ".idr" => "idris2",
        ".v" => "coq",
        ".jl" => "julia",
        ".zig" => "zig",
        ".ex" | ".exs" => "elixir",
        ".gleam" => "gleam",
        ".py" => "python",
        ".rs" => "rust",
        ".go" => "go",
        ".ts" => "typescript",
        ".js" | ".mjs" => "javascript",
        ".ml" => "ocaml",
        ".adb" | ".ads" => "ada",
        ".nix" => "nix",
        _ => return None,
    })
}

/// An extension implies a language already covered by a marker.
fn covered_by(lang: &str) -> &'static [&'static str] {
    match lang {
        "typescript" | "javascript" | "rescript" => &["node", "deno"],
        "erlang" => &["elixir"],
        "idris2" => &["idris2"],
        _ => &[],
    }
}

fn default_command(lang: &str, cat: &str) -> Option<&'static str> {
    Some(match (lang, cat) {
        ("rust", "unit") => "cargo test --workspace --lib --bins --locked",
        ("rust", "build") => "cargo build --workspace --all-targets --locked",
        ("rust", "smoke") => "cargo test --workspace --locked --test smoke",
        ("rust", "p2p") => "cargo test --workspace --locked --test p2p",
        ("elixir", "unit") => "mix test --exclude smoke --exclude p2p",
        ("elixir", "build") => "mix compile --warnings-as-errors",
        ("elixir", "smoke") => "mix test --only smoke",
        ("elixir", "p2p") => "mix test --only p2p",
        ("go", "unit") => "go test ./...",
        ("go", "build") => "go build ./...",
        ("go", "smoke") => "go test -run Smoke ./...",
        ("go", "p2p") => "go test -run P2P ./...",
        ("node", "unit") => "npm test",
        ("node", "build") => "npm run build",
        ("node", "smoke") => "npm run smoke",
        ("node", "p2p") => "npm run p2p",
        ("python", "unit") => "python -m pytest -m 'not smoke and not p2p'",
        ("python", "build") => "python -m compileall -q .",
        ("python", "smoke") => "python -m pytest -m smoke",
        ("python", "p2p") => "python -m pytest -m p2p",
        ("zig", "unit") => "zig build test",
        ("zig", "build") => "zig build",
        _ => return None,
    })
}

fn just_recipes_for(cat: &str) -> &'static [&'static str] {
    match cat {
        "unit" => &["unit", "test"],
        "smoke" => &["smoke"],
        "build" => &["build"],
        _ => &["p2p"],
    }
}

fn convention_file(cat: &str) -> String {
    format!("tests/{cat}.sh")
}

fn dirname(f: &str) -> &str {
    f.rfind('/').map(|i| &f[..i]).filter(|d| !d.is_empty()).unwrap_or(".")
}

fn basename(f: &str) -> &str {
    f.rsplit('/').next().unwrap_or(f)
}

/// Extension with its dot; a leading dot alone is not an extension.
fn ext(base: &str) -> &str {
    match base.rfind('.') {
        Some(i) if i > 0 => &base[i..],
        _ => "",
    }
}

fn tstr(v: &T) -> String {
    match v {
        T::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn list_files(root: &Path) -> Vec<String> {
    fn walk(dir: &Path, rel: &str, out: &mut Vec<String>) {
        let Ok(rd) = fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            let path = e.path();
            let Ok(ft) = e.file_type() else { continue };
            let is_dir = ft.is_dir();
            let link_to_dir = ft.is_symlink() && fs::metadata(&path).map(|m| m.is_dir()).unwrap_or(false);
            let relpath = if rel.is_empty() { name.clone() } else { format!("{rel}/{name}") };
            if is_dir {
                if !is_skipped_dir(&name) {
                    walk(&path, &relpath, out);
                }
            } else if !link_to_dir {
                out.push(relpath);
            }
        }
    }
    let mut out = Vec::new();
    walk(root, "", &mut out);
    out.sort();
    out
}

fn just_recipes(root: &Path) -> BTreeSet<String> {
    for name in ["justfile", "Justfile", ".justfile"] {
        let p = root.join(name);
        if p.is_file() {
            let text = fs::read(&p).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
            return text.lines().filter_map(recipe_name).collect();
        }
    }
    BTreeSet::new()
}

/// `^name[^:\n=]*:(?!=)` on one line.
fn recipe_name(line: &str) -> Option<String> {
    let n = line.find(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '-')).unwrap_or(line.len());
    if n == 0 {
        return None;
    }
    let rest = &line[n..];
    let colon = rest.find(|c| c == ':' || c == '=')?;
    if !rest[colon..].starts_with(':') || rest[colon + 1..].starts_with('=') {
        return None;
    }
    Some(line[..n].to_string())
}

fn load_manifest(root: &Path, errors: &mut Vec<String>) -> Table {
    let p = root.join(".proven.toml");
    let real = fs::canonicalize(&p).ok().filter(|r| r.starts_with(root));
    let Some(real) = real.filter(|r| r.is_file()) else {
        errors.push("manifest-missing: .proven.toml is required (it may be minimal: schema only)".into());
        return Table::new();
    };
    let text = match fs::read_to_string(&real) {
        Ok(t) => t,
        Err(e) => {
            errors.push(format!("manifest-unparseable: {e}"));
            return Table::new();
        }
    };
    let m: Table = match toml::from_str(&text) {
        Ok(m) => m,
        Err(e) => {
            errors.push(format!("manifest-unparseable: {e}"));
            return Table::new();
        }
    };
    if m.get("schema").and_then(T::as_str) != Some(SCHEMA) {
        let got = m.get("schema").map(tstr).unwrap_or_else(|| "none".into());
        errors.push(format!("manifest-schema: schema must be \"{SCHEMA}\", got {got}"));
    }
    m
}

fn sub<'a>(t: &'a Table, k: &str) -> Option<&'a Table> {
    t.get(k).and_then(T::as_table)
}

fn marker_languages(files: &[String]) -> (BTreeMap<String, String>, BTreeMap<String, Vec<String>>) {
    let mut roots: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let workspaces: Vec<&str> =
        files.iter().filter(|f| basename(f) == "go.work").map(|f| dirname(f)).collect();
    let mut sorted: Vec<&String> = files.iter().collect();
    sorted.sort_by_key(|f| (f.matches('/').count(), f.to_string()));
    for f in sorted {
        let base = basename(f);
        let Some(lang) = marker(base).or_else(|| suffix_marker(ext(base))) else { continue };
        let d = dirname(f);
        if lang == "go"
            && workspaces.iter().any(|w| *w != d && (*w == "." || d.starts_with(&format!("{w}/"))))
        {
            continue; // a module inside a go.work workspace is covered by the workspace root
        }
        let v = roots.entry(lang.to_string()).or_default();
        if !v.iter().any(|x| x == d) {
            v.push(d.to_string());
        }
    }
    let first = roots.iter().map(|(l, d)| (l.clone(), d[0].clone())).collect();
    (first, roots)
}

fn read_ignores(m: &Table, errors: &mut Vec<String>) -> BTreeMap<String, String> {
    let mut ignores = BTreeMap::new();
    if let Some(ig) = sub(m, "languages").and_then(|l| sub(l, "ignore")) {
        for (name, v) in ig {
            let reason = v.as_table().and_then(|t| t.get("reason")).map(tstr).unwrap_or_default();
            if reason.trim().is_empty() {
                errors.push(format!("language-ignore-no-reason: [languages.ignore.{name}] needs a written reason"));
            } else {
                ignores.insert(name.clone(), reason);
            }
        }
    }
    ignores
}

type Langs = (BTreeMap<String, String>, BTreeMap<String, Vec<String>>);

fn detect_languages(files: &[String], m: &Table, ignores: &BTreeMap<String, String>) -> Langs {
    let (mut langs, roots) = marker_languages(files);
    let declared: BTreeSet<String> = sub(m, "languages")
        .and_then(|l| l.get("declare"))
        .and_then(T::as_array)
        .map(|a| a.iter().map(tstr).collect())
        .unwrap_or_default();
    for l in &declared {
        langs.entry(l.clone()).or_insert_with(|| ".".into());
    }
    let ext_langs: BTreeSet<&str> = files.iter().filter_map(|f| source_lang(ext(basename(f)))).collect();
    for lang in ext_langs {
        if langs.contains_key(lang) || declared.contains(lang) {
            continue;
        }
        if covered_by(lang).iter().any(|c| langs.contains_key(*c)) {
            continue;
        }
        if ignores.contains_key(lang) || ignores.contains_key(&format!(".{lang}")) {
            continue;
        }
        langs.insert(lang.to_string(), ".".into());
    }
    // Only Go plans every independent module root; other languages use their first root.
    let per_lang = langs
        .iter()
        .map(|(l, d)| {
            let dirs = if l == "go" { roots.get(l).cloned() } else { None };
            (l.clone(), dirs.filter(|v| !v.is_empty()).unwrap_or_else(|| vec![d.clone()]))
        })
        .collect();
    (langs, per_lang)
}

fn fmt_date((y, m, d): Date) -> String {
    format!("{y:04}-{m:02}-{d:02}")
}

struct Ctx {
    errors: Vec<String>,
    waivers: Vec<Value>,
    today: Date,
    roots: BTreeMap<String, Vec<String>>,
    recipes: BTreeSet<String>,
    filenames: BTreeSet<String>,
}

fn check_waiver(wv: &T, cat: &str, lang: &str, ctx: &mut Ctx) {
    let t = wv.as_table();
    let reason = t.and_then(|t| t.get("reason")).map(tstr).unwrap_or_default();
    let exp = t.and_then(|t| t.get("until")).and_then(|u| date::parse(&tstr(u)));
    match exp {
        Some(exp) if !reason.trim().is_empty() => {
            if exp < ctx.today {
                ctx.errors.push(format!("waiver-expired: {cat}/{lang} waiver expired {}: {}", fmt_date(exp), reason.trim()));
            } else {
                ctx.waivers.push(json!({"category": cat, "lang": lang, "reason": reason.trim(), "until": fmt_date(exp)}));
            }
        }
        _ => ctx.errors.push(format!("waiver-invalid: {cat}/{lang} waiver needs reason and until=YYYY-MM-DD")),
    }
}

fn resolve_command(entry: &Table, per: &Table, cat: &str, lang: &str, ctx: &Ctx) -> (Option<String>, &'static str) {
    if let Some(c) = per.get("command").or_else(|| entry.get("command")) {
        return (Some(tstr(c)), "manifest");
    }
    for r in just_recipes_for(cat) {
        if ctx.recipes.contains(*r) {
            return (Some(format!("just {r}")), "justfile");
        }
    }
    let cf = convention_file(cat);
    if ctx.filenames.contains(&cf) {
        return (Some(format!("bash {cf}")), "convention");
    }
    match default_command(lang, cat) {
        Some(d) => (Some(d.to_string()), "default"),
        None => (None, ""),
    }
}

fn job_suffix(d: &str) -> String {
    let mut out = String::new();
    let mut pending = false;
    for c in d.chars() {
        if c.is_ascii_alphanumeric() {
            if pending && !out.is_empty() {
                out.push('_');
            }
            pending = false;
            out.push(c);
        } else {
            pending = true;
        }
    }
    out
}

fn plan_category(cat: &str, lang: &str, cmeta: &Table, ctx: &mut Ctx) -> (Vec<Value>, Option<Value>) {
    let empty = Table::new();
    let entry = sub(cmeta, cat).unwrap_or(&empty);
    let per = sub(entry, lang).unwrap_or(&empty);
    if let Some(na) = per.get("na").or_else(|| entry.get("na")) {
        let reason = tstr(na);
        if reason.trim().is_empty() {
            ctx.errors.push(format!("na-no-reason: {cat}/{lang} is N/A with an empty reason"));
            return (vec![], None);
        }
        return (vec![], Some(json!({"category": cat, "lang": lang, "reason": reason})));
    }
    if let Some(wv) = per.get("waiver").or_else(|| entry.get("waiver")) {
        check_waiver(wv, cat, lang, ctx);
        return (vec![], None);
    }
    let (cmd, source) = resolve_command(entry, per, cat, lang, ctx);
    let Some(cmd) = cmd else {
        ctx.errors.push(format!(
            "missing-runner: {cat}/{lang}: no command (manifest, justfile recipe, tests/{cat}.sh or language default), no N/A reason, no waiver"
        ));
        return (vec![], None);
    };
    if cmd.trim().is_empty() {
        ctx.errors.push(format!("command-empty: {cat}/{lang} manifest command is empty"));
        return (vec![], None);
    }
    // only language defaults run in the project dir
    let dirs: Vec<String> = if source == "default" {
        ctx.roots.get(lang).cloned().unwrap_or_else(|| vec![".".into()])
    } else {
        vec![".".into()]
    };
    let multi = dirs.len() > 1;
    let jobs = dirs
        .iter()
        .map(|d| {
            let id = if multi { format!("{cat}-{lang}-{}", job_suffix(d)) } else { format!("{cat}-{lang}") };
            json!({"id": id, "category": cat, "lang": lang, "dir": d, "command": cmd, "source": source})
        })
        .collect();
    (jobs, None)
}

fn plan_benches(m: &Table, errors: &mut Vec<String>) -> Vec<Value> {
    let mut out = Vec::new();
    if let Some(b) = sub(m, "bench") {
        for (name, v) in b {
            let t = v.as_table();
            let cmd = t.and_then(|t| t.get("command")).map(tstr).unwrap_or_default();
            let Some(t) = t.filter(|_| !cmd.trim().is_empty()) else {
                errors.push(format!("bench-invalid: [bench.{name}] needs a command"));
                continue;
            };
            out.push(json!({
                "name": name,
                "command": cmd,
                "metric": t.get("metric").map(tstr).unwrap_or_else(|| "seconds".into()),
                "lower_is_better": t.get("lower_is_better").and_then(T::as_bool).unwrap_or(true),
                "baselining": t.get("baselining").and_then(T::as_bool).unwrap_or(false),
            }));
        }
    }
    out
}

pub fn run(args: &[String]) -> i32 {
    let Some(first) = args.first() else {
        eprintln!("proven-gate detect: usage: detect REPO_DIR [--today YYYY-MM-DD] [--categories a,b]");
        return 2;
    };
    let root = match fs::canonicalize(first) {
        Ok(r) if r.is_dir() && !first.contains('\0') => r,
        _ => {
            eprintln!("proven-gate detect: {first} is not a directory");
            return 2;
        }
    };
    let mut today = date::today();
    let mut cats: Vec<String> = KNOWN_CATEGORIES.iter().map(|s| s.to_string()).collect();
    let mut i = 1;
    while i < args.len() {
        match (args[i].as_str(), args.get(i + 1)) {
            ("--today", Some(v)) => match date::parse(v) {
                Some(d) => today = d,
                None => {
                    eprintln!("proven-gate detect: --today needs YYYY-MM-DD, got {v}");
                    return 2;
                }
            },
            ("--categories", Some(v)) => cats = v.split(',').filter(|c| !c.is_empty()).map(String::from).collect(),
            (other, _) => {
                eprintln!("proven-gate detect: unknown argument {other}");
                return 2;
            }
        }
        i += 2;
    }
    let mut errors = Vec::new();
    let m = load_manifest(&root, &mut errors);
    let files = list_files(&root);
    let ignores = read_ignores(&m, &mut errors);
    let (langs, roots) = detect_languages(&files, &m, &ignores);
    let empty = Table::new();
    let cmeta = sub(&m, "categories").unwrap_or(&empty);
    for name in cmeta.keys() {
        if !KNOWN_CATEGORIES.contains(&name.as_str()) {
            errors.push(format!(
                "category-unknown: [categories.{name}] is not a category this release knows (known: {}); an unknown name is never ignored",
                KNOWN_CATEGORIES.join(", ")
            ));
        }
    }
    let mut ctx = Ctx {
        errors,
        waivers: vec![],
        today,
        roots,
        recipes: just_recipes(&root),
        filenames: files.iter().cloned().collect(),
    };
    let (mut jobs, mut na_list) = (Vec::new(), Vec::new());
    for lang in langs.keys() {
        if ignores.contains_key(lang) {
            continue;
        }
        for cat in &cats {
            let (planned, na) = plan_category(cat, lang, cmeta, &mut ctx);
            jobs.extend(planned);
            na_list.extend(na);
        }
    }
    let benches = plan_benches(&m, &mut ctx.errors);
    let ok = ctx.errors.is_empty();
    let plan = json!({
        "ok": ok, "errors": ctx.errors, "languages": langs.keys().collect::<Vec<_>>(), "jobs": jobs,
        "waivers": ctx.waivers, "na": na_list, "benches": benches, "categories": cats,
    });
    println!("{}", serde_json::to_string_pretty(&plan).unwrap_or_default());
    if ok { 0 } else { 1 }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str, files: &[(&str, &str)]) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("proven-gate-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        for (p, c) in files {
            let f = d.join(p);
            fs::create_dir_all(f.parent().unwrap()).unwrap();
            fs::write(f, c).unwrap();
        }
        d
    }

    fn plan(d: &Path, today: &str) -> (i32, Value) {
        // run() prints; re-plan through the same pieces for assertions
        let code = run(&[d.to_string_lossy().into(), "--today".into(), today.into()]);
        (code, Value::Null)
    }

    #[test]
    fn recipe_names() {
        assert_eq!(recipe_name("test: build"), Some("test".into()));
        assert_eq!(recipe_name("smoke arg:"), Some("smoke".into()));
        assert_eq!(recipe_name("smoke arg='x':"), None);
        assert_eq!(recipe_name("v := 1"), None);
        assert_eq!(recipe_name("x:= 1"), None);
        assert_eq!(recipe_name("  indented:"), None);
    }

    #[test]
    fn missing_manifest_fails() {
        let d = tmp("nomanifest", &[("a.sh", "echo")]);
        assert_eq!(plan(&d, "2026-01-01").0, 1);
    }

    #[test]
    fn minimal_shell_repo_with_conventions_is_ok() {
        let d = tmp(
            "shell",
            &[
                (".proven.toml", "schema = \"proven/manifest/v1\"\n[categories.p2p]\nna = \"no seam\"\n"),
                ("tests/unit.sh", ""),
                ("tests/smoke.sh", ""),
                ("tests/build.sh", ""),
            ],
        );
        assert_eq!(plan(&d, "2026-01-01").0, 0);
    }

    #[test]
    fn unknown_language_and_unknown_category_fail() {
        let d = tmp("unk", &[(".proven.toml", "schema = \"proven/manifest/v1\"\n"), ("x.swift", "")]);
        assert_eq!(plan(&d, "2026-01-01").0, 1);
        let d = tmp("cat", &[(".proven.toml", "schema = \"proven/manifest/v1\"\n[categories.e2e]\nna = \"x\"\n")]);
        assert_eq!(plan(&d, "2026-01-01").0, 1);
    }

    #[test]
    fn waiver_expires() {
        let toml = "schema = \"proven/manifest/v1\"\n[categories.unit.waiver]\nreason = \"r\"\nuntil = \"2026-06-01\"\n[categories.smoke]\nna = \"n\"\n[categories.build]\nna = \"n\"\n[categories.p2p]\nna = \"n\"\n";
        let d = tmp("waiver", &[(".proven.toml", toml), ("a.sh", "")]);
        assert_eq!(plan(&d, "2026-05-31").0, 0);
        assert_eq!(plan(&d, "2026-06-02").0, 1);
    }

    #[test]
    fn suffix_ids() {
        assert_eq!(job_suffix("a/b-c"), "a_b_c");
        assert_eq!(job_suffix("."), "");
    }
}
