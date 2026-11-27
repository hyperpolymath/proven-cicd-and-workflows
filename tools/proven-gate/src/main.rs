// SPDX-License-Identifier: MPL-2.0
//! proven-gate: the three checks behind the `proven` umbrella workflow.
//!
//!   proven-gate detect REPO_DIR [--today YYYY-MM-DD] [--categories a,b]
//!   proven-gate integrity CALLER_WORKFLOW_PATH      (root: $PROVEN_ROOT or cwd)
//!   proven-gate bench-gate CURRENT [--history v1,v2] [--higher-is-better] [--baselining]
//!
//! Exit status for every subcommand: 0 ok, 1 defect found, 2 could not run
//! (bench-gate: 1 Unacceptable, 3 Acceptable, 2 no baseline). Fail closed:
//! absence is never a pass (ER-A8).

mod bench;
mod date;
mod detect;
mod integrity;

use std::process::exit;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("detect") => detect::run(&args[1..]),
        Some("integrity") => integrity::run(&args[1..]),
        Some("bench-gate") => bench::run(&args[1..]),
        _ => {
            eprintln!("usage: proven-gate (detect REPO_DIR | integrity CALLER_PATH | bench-gate CURRENT)");
            2
        }
    };
    exit(code);
}
