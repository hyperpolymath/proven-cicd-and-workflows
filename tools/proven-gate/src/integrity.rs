// SPDX-License-Identifier: MPL-2.0
//! ER-A8 workflow integrity: no pass on absence.
//!
//! `integrity CALLER_WORKFLOW_PATH` (repository root: $PROVEN_ROOT or cwd).
//! A missing, skipped or unparseable workflow fails. Exit 0 ok, 1 defect, 2 could not run.

use serde_yaml::{Mapping, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Component, Path, PathBuf};

fn load(p: &Path) -> Option<Mapping> {
    let text = fs::read_to_string(p).ok()?;
    match serde_yaml::from_str::<Value>(&text).ok()? {
        Value::Mapping(m) => Some(m),
        _ => None,
    }
}

fn get<'a>(m: &'a Mapping, k: &str) -> Option<&'a Value> {
    m.get(Value::String(k.into()))
}

fn has(m: &Mapping, k: &str) -> bool {
    get(m, k).is_some()
}

fn jobs_of(m: &Mapping) -> Option<&Mapping> {
    get(m, "jobs").and_then(Value::as_mapping)
}

fn workflows() -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir(".github/workflows")
        .map(|rd| rd.flatten().map(|e| e.path()).collect())
        .unwrap_or_default();
    v.retain(|p| matches!(p.extension().and_then(|e| e.to_str()), Some("yml" | "yaml")));
    v.sort();
    v
}

fn key_str(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

/// continue-on-error values GitHub would read as true (literal, string or expression).
fn may_be_true(v: &Value) -> bool {
    !(matches!(v, Value::Bool(false)) || matches!(v, Value::String(s) if s.trim().eq_ignore_ascii_case("false")))
}

fn lexical(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

pub fn run(args: &[String]) -> i32 {
    let root = std::env::var("PROVEN_ROOT").ok().filter(|s| !s.is_empty()).map(PathBuf::from);
    let root = match root.map(Ok).unwrap_or_else(std::env::current_dir).and_then(fs::canonicalize) {
        Ok(r) => r,
        Err(e) => {
            println!("::error::cannot resolve repository root: {e}");
            return 2;
        }
    };
    if std::env::set_current_dir(&root).is_err() {
        println!("::error::cannot enter repository root");
        return 2;
    }
    let Some(arg) = args.first().filter(|a| !a.is_empty()) else {
        println!("::error::usage: proven-gate integrity CALLER_WORKFLOW_PATH");
        return 2;
    };
    let joined = root.join(arg);
    let real = fs::canonicalize(&joined).unwrap_or_else(|_| lexical(&joined));
    let Ok(rel) = real.strip_prefix(&root) else {
        println!("::error::caller workflow path escapes the repository");
        return 2;
    };
    let caller = rel.to_path_buf();
    let cname = caller.display().to_string();

    let mut bad: Vec<String> = Vec::new();
    let mut err = |m: String| {
        println!("::error::ER-A8: {m}");
        bad.push(m);
    };

    let files = workflows();
    if files.is_empty() {
        err("no workflow files under .github/workflows".into());
    }
    for f in &files {
        match load(f) {
            Some(d) if jobs_of(&d).is_some_and(|j| !j.is_empty()) => {}
            _ => err(format!("{} is unparseable or has no jobs", f.display())),
        }
    }
    if !Path::new(".github/workflows/proven-lock-gate.yml").is_file() {
        err("stamped .github/workflows/proven-lock-gate.yml is missing (SR-005)".into());
    }

    let is_umbrella = |s: &str| s == "./.github/workflows/proven.yml" || s.contains("/.github/workflows/proven.yml@");
    match caller.is_file().then(|| load(&caller)).flatten() {
        None => err(format!("caller workflow {cname} is missing or unparseable")),
        Some(d) => {
            // YAML 1.1 parses a bare `on` key as true
            let on = get(&d, "on").or_else(|| d.get(Value::Bool(true))).cloned().unwrap_or(Value::Null);
            let trig: BTreeSet<String> = match &on {
                Value::Mapping(m) => m.keys().filter_map(key_str).collect(),
                Value::Sequence(s) => s.iter().filter_map(key_str).collect(),
                other => key_str(other).into_iter().collect(),
            };
            let mut found = false;
            if let Some(jobs) = jobs_of(&d) {
                for (k, v) in jobs {
                    let Some(v) = v.as_mapping() else { continue };
                    let uses = get(v, "uses").and_then(Value::as_str).unwrap_or("");
                    if !is_umbrella(uses) {
                        continue;
                    }
                    found = true;
                    let k = key_str(k).unwrap_or_default();
                    if k != "proven" {
                        err(format!("{cname}: the umbrella job id must be 'proven' (required check 'proven / verdict'), found '{k}'"));
                    }
                    if has(v, "if") {
                        err(format!("{cname}: job '{k}' has an 'if:'; a skipped gate is not a pass"));
                    }
                    if has(v, "continue-on-error") {
                        err(format!("{cname}: job '{k}' sets continue-on-error"));
                    }
                }
            }
            if !found {
                err(format!("{cname} has no job calling the proven umbrella workflow"));
            }
            if !trig.contains("pull_request") && !trig.contains("merge_group") {
                err(format!("{cname} is not triggered by pull_request or merge_group"));
            }
            if let Value::Mapping(m) = &on {
                if let Some(Value::Mapping(pr)) = get(m, "pull_request") {
                    for key in ["branches", "branches-ignore", "paths", "paths-ignore"] {
                        if has(pr, key) {
                            err(format!("{cname}: on.pull_request.{key} can skip the required check; remove the filter"));
                        }
                    }
                }
            }
        }
    }

    for f in files.iter().filter(|f| f.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("proven"))) {
        let Some(wf) = load(f) else { continue };
        let Some(jobs) = jobs_of(&wf) else { continue };
        for (jk, jv) in jobs {
            let (Some(jk), Some(jv)) = (key_str(jk), jv.as_mapping()) else { continue };
            if get(jv, "continue-on-error").is_some_and(may_be_true) {
                err(format!("{}: job '{jk}' sets continue-on-error", f.display()));
            }
            for st in get(jv, "steps").and_then(Value::as_sequence).into_iter().flatten() {
                if st.as_mapping().and_then(|s| get(s, "continue-on-error")).is_some_and(may_be_true) {
                    err(format!("{}: a step in job '{jk}' sets continue-on-error", f.display()));
                }
            }
        }
    }
    if bad.is_empty() {
        println!("ER-A8 integrity: ok ({} workflow files)", files.len());
        0
    } else {
        1
    }
}
