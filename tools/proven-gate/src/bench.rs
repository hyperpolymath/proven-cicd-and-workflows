// SPDX-License-Identifier: MPL-2.0
//! Six Sigma bench gate (TESTING-TAXONOMY Part IV).
//!
//! Baseline = mean of the last 10 history values (main runs). The rounded
//! worse-than-baseline percentage drives the class:
//!   Unacceptable   > 50% worse    exit 1 (blocks)
//!   Acceptable     20..50% worse  exit 3 (needs the bench-approved label)
//!   Ordinary       within 20%     exit 0
//!   Extraordinary  > 20% better   exit 0 (flag)
//! No history, a non-positive baseline or a non-finite value is exit 2
//! unless --baselining, which records and passes.

use serde_json::json;

struct Opts {
    current: f64,
    history: Vec<f64>,
    higher_is_better: bool,
    baselining: bool,
}

fn parse_args(args: &[String]) -> Result<Opts, String> {
    let mut current = None;
    let (mut history_raw, mut higher, mut baselining) = (String::new(), false, false);
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--history" if i + 1 < args.len() => {
                history_raw = args[i + 1].clone();
                i += 1;
            }
            s if s.starts_with("--history=") => history_raw = s["--history=".len()..].to_string(),
            "--higher-is-better" => higher = true,
            "--baselining" => baselining = true,
            s if current.is_none() && !s.starts_with("--") => {
                current = Some(s.parse::<f64>().map_err(|_| format!("CURRENT is not a number: {s}"))?)
            }
            other => return Err(format!("unknown argument {other}")),
        }
        i += 1;
    }
    let history = history_raw
        .split(',')
        .filter(|x| !x.trim().is_empty())
        .map(|x| x.trim().parse::<f64>().map_err(|_| format!("history value is not a number: {x}")))
        .collect::<Result<Vec<_>, _>>()?;
    let current = current.ok_or("usage: proven-gate bench-gate CURRENT [--history v1,v2]")?;
    Ok(Opts { current, history, higher_is_better: higher, baselining })
}

/// (class, exit code, worse percentage) for a finite current value and a positive baseline.
pub fn classify(current: f64, base: f64, higher_is_better: bool) -> (&'static str, i32, f64) {
    let worse = if higher_is_better { (base - current) / base } else { (current - base) / base };
    let pct = (worse * 10_000.0).round() / 100.0; // rounded, so float noise cannot slip under a boundary
    let (class, rc) = if pct > 50.0 {
        ("Unacceptable", 1)
    } else if pct >= 20.0 {
        ("Acceptable", 3)
    } else if pct < -20.0 {
        ("Extraordinary", 0)
    } else {
        ("Ordinary", 0)
    };
    (class, rc, pct)
}

pub fn run(args: &[String]) -> i32 {
    let o = match parse_args(args) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("proven-gate bench-gate: {e}");
            return 2;
        }
    };
    if !o.current.is_finite() || o.history.iter().any(|x| !x.is_finite()) {
        println!("{}", json!({"class": "NoBaseline", "current": o.current.to_string()}));
        eprintln!("non-finite benchmark value: no pass on garbage");
        return 2;
    }
    let last10: Vec<f64> = o.history.iter().rev().take(10).rev().copied().collect();
    if last10.is_empty() {
        if o.baselining {
            println!("{}", json!({"class": "Baselining", "baseline": null, "current": o.current}));
            return 0;
        }
        println!("{}", json!({"class": "NoBaseline", "current": o.current}));
        eprintln!("no history on main and [bench.*] baselining is not set: no pass on absence");
        return 2;
    }
    let base = last10.iter().sum::<f64>() / last10.len() as f64;
    if base <= 0.0 {
        // a zero or negative baseline cannot express a percentage regression
        println!("{}", json!({"class": "NoBaseline", "baseline": base}));
        return 2;
    }
    let (class, rc, pct) = classify(o.current, base, o.higher_is_better);
    println!("{}", json!({"class": class, "baseline": base, "current": o.current, "worse_pct": pct, "n": last10.len()}));
    rc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn boundaries() {
        assert_eq!(classify(151.0, 100.0, false).0, "Unacceptable");
        assert_eq!(classify(150.0, 100.0, false).0, "Acceptable");
        assert_eq!(classify(120.0, 100.0, false).0, "Acceptable");
        assert_eq!(classify(119.0, 100.0, false).0, "Ordinary");
        assert_eq!(classify(70.0, 100.0, false).0, "Extraordinary");
    }

    #[test]
    fn float_noise_at_twenty_percent_is_acceptable() {
        assert_eq!(classify(1.2, 1.0, false).0, "Acceptable");
    }

    #[test]
    fn higher_is_better_flips_direction() {
        assert_eq!(classify(60.0, 100.0, true), ("Acceptable", 3, 40.0));
    }

    #[test]
    fn only_last_ten_count() {
        let args: Vec<String> = ["130", "--history", "1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,100,100,100,100,100,100,100,100,100,100"]
            .iter().map(|s| s.to_string()).collect();
        assert_eq!(run(&args), 3);
    }

    #[test]
    fn absence_and_garbage_fail() {
        let a = |v: &[&str]| run(&v.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        assert_eq!(a(&["100"]), 2);
        assert_eq!(a(&["100", "--baselining"]), 0);
        assert_eq!(a(&["nan", "--history", "100"]), 2);
        assert_eq!(a(&["100", "--history", "nan,100"]), 2);
        assert_eq!(a(&["5", "--history=-10"]), 2);
    }
}
