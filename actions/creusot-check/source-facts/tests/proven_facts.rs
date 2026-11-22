// SPDX-License-Identifier: MPL-2.0
//! Counted evidence for creusot-source-facts.
//!
//! R: seeded property tests (fixed seed, at least 100 cases each) that check
//! the binary against a reference three-valued cfg evaluator.
//! C: conformance vectors whose transcripts are pinned by SHA-256.
//! Set `SOURCE_FACTS_PRINT_DIGESTS=1` to print fresh digests; that run fails.

mod support {
    pub mod sha256;
}
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};
use support::sha256;

const SEED: u64 = 0x4352_5553_4f54_4646;
const CASES: usize = 256;

/// xorshift64*: a fixed, dependency-free generator so every run sees the same cases.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tri {
    Yes,
    No,
    Unknown,
}
fn and(a: Tri, b: Tri) -> Tri {
    match (a, b) {
        (Tri::No, _) | (_, Tri::No) => Tri::No,
        (Tri::Yes, Tri::Yes) => Tri::Yes,
        _ => Tri::Unknown,
    }
}
fn or(a: Tri, b: Tri) -> Tri {
    match (a, b) {
        (Tri::Yes, _) | (_, Tri::Yes) => Tri::Yes,
        (Tri::No, Tri::No) => Tri::No,
        _ => Tri::Unknown,
    }
}
fn not(a: Tri) -> Tri {
    match a {
        Tri::Yes => Tri::No,
        Tri::No => Tri::Yes,
        Tri::Unknown => Tri::Unknown,
    }
}

/// A random cfg predicate and its reference value.
fn predicate(rng: &mut Rng, depth: u32) -> (String, Tri) {
    let leaf = depth == 0 || rng.below(3) == 0;
    if leaf {
        return match rng.below(5) {
            0 => ("creusot".into(), Tri::Yes),
            1 => ("test".into(), Tri::No),
            2 => ("feature = \"proof\"".into(), Tri::Unknown),
            3 => ("creusot = \"x\"".into(), Tri::Unknown),
            _ => ("unix".into(), Tri::Unknown),
        };
    }
    match rng.below(3) {
        0 => {
            let (text, value) = predicate(rng, depth - 1);
            (format!("not({text})"), not(value))
        }
        kind => {
            let any = kind == 1;
            let mut value = if any { Tri::No } else { Tri::Yes };
            let mut parts = Vec::new();
            for _ in 0..rng.below(4) {
                let (text, v) = predicate(rng, depth - 1);
                value = if any { or(value, v) } else { and(value, v) };
                parts.push(text);
            }
            let name = if any { "any" } else { "all" };
            (format!("{name}({})", parts.join(", ")), value)
        }
    }
}

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_creusot-source-facts")
}

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("source-facts-{}-{tag}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// Exit code, stdout and stderr of one run.
fn run(args: &[&str]) -> (i32, String, String) {
    let out = Command::new(binary())
        .args(args)
        .output()
        .expect("binary runs");
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8(out.stdout).expect("utf-8 stdout"),
        String::from_utf8(out.stderr).expect("utf-8 stderr"),
    )
}

fn facts_of(dir: &Path, source: &str) -> (i32, String, String) {
    let file = dir.join("case.rs");
    fs::write(&file, source).expect("write case");
    run(&[file.to_str().expect("utf-8 path")])
}

/// What the tool must report for one proof attribute under `value`.
fn expect(value: Tri, out: &(i32, String, String), row: &str, case: &str) {
    match value {
        Tri::Yes => {
            assert_eq!(out.0, 0, "{case}: {out:?}");
            assert!(out.1.starts_with(row), "{case}: {out:?}");
            assert_eq!(out.1.lines().count(), 1, "{case}: {out:?}");
        }
        Tri::No => assert_eq!((out.0, out.1.as_str()), (0, ""), "{case}"),
        Tri::Unknown => {
            assert_eq!((out.0, out.1.as_str()), (2, ""), "{case}");
            assert!(out.2.contains("NOT INSPECTED"), "{case}: {out:?}");
            assert!(
                out.2.contains("unresolved cfg condition"),
                "{case}: {out:?}"
            );
        }
    }
}

#[test]
fn prop_cfg_attr_contracts_follow_three_valued_logic() {
    let mut rng = Rng(SEED);
    let dir = scratch("cfg-attr");
    for _ in 0..CASES {
        let (text, value) = predicate(&mut rng, 3);
        let case = format!("#[cfg_attr({text}, ensures(true))]\nfn f() {{}}\n");
        expect(value, &facts_of(&dir, &case), "contract\t", &case);
    }
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn prop_cfg_scopes_hide_or_credit_nested_obligations() {
    let mut rng = Rng(SEED ^ 1);
    let dir = scratch("cfg-scope");
    for _ in 0..CASES {
        let (text, value) = predicate(&mut rng, 3);
        let case = format!("#[cfg({text})]\nmod m {{\n    #[logic]\n    fn f() {{}}\n}}\n");
        expect(value, &facts_of(&dir, &case), "obligation\t", &case);
    }
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn prop_cfg_inside_cfg_attr_is_only_trusted_when_resolved() {
    let mut rng = Rng(SEED ^ 2);
    let dir = scratch("cfg-in-cfg-attr");
    for _ in 0..CASES {
        let (q, included) = predicate(&mut rng, 2);
        let (p, value) = predicate(&mut rng, 2);
        let expected = match included {
            Tri::No => Tri::Yes,
            _ if included == Tri::Yes || value == Tri::Yes => value,
            _ => Tri::Unknown,
        };
        let case = format!("#[cfg_attr({q}, cfg({p}))]\nfn f() {{\n    proof_assert!(true);\n}}\n");
        expect(expected, &facts_of(&dir, &case), "obligation\t", &case);
    }
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn prop_nesting_beyond_the_bound_is_refused() {
    let mut rng = Rng(SEED ^ 3);
    let dir = scratch("depth");
    for _ in 0..128 {
        let depth = rng.below(80) as usize;
        let mut meta = String::from("logic");
        for _ in 0..depth {
            meta = format!("cfg_attr(creusot, {meta})");
        }
        let out = facts_of(&dir, &format!("#[{meta}]\nfn f() {{}}\n"));
        if depth <= 65 {
            assert_eq!(out.0, 0, "depth {depth}: {out:?}");
            assert!(out.1.starts_with("obligation\t"), "depth {depth}");
        } else {
            assert_eq!((out.0, out.1.as_str()), (2, ""), "depth {depth}");
            assert!(out.2.contains("inspection bound"), "depth {depth}");
        }
    }
    let _ = fs::remove_dir_all(dir);
}

/// One vector: name, source (None means the path is passed but not created), extra args.
struct Vector {
    name: &'static str,
    source: Option<&'static str>,
    digest: &'static str,
}

fn print_mode() -> bool {
    std::env::var_os("SOURCE_FACTS_PRINT_DIGESTS").is_some()
}

fn transcript(out: &(i32, String, String), dir: &str) -> String {
    format!("exit {}\n--stdout\n{}--stderr\n{}", out.0, out.1, out.2).replace(dir, "<dir>")
}

fn check(name: &str, text: &str, digest: &str, printed: &mut Vec<String>) {
    let actual = sha256::hex(text.as_bytes());
    if print_mode() {
        printed.push(format!("{name} {actual}"));
    } else {
        assert_eq!(actual, digest, "{name}:\n{text}");
    }
}

fn finish(printed: Vec<String>) {
    if print_mode() {
        panic!("digests:\n{}", printed.join("\n"));
    }
}

#[test]
fn prop_sha256_matches_fips_180_4_examples() {
    assert_eq!(
        sha256::hex(b"abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(
        sha256::hex(b""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    assert_eq!(
        sha256::hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    );
}

#[test]
fn prop_every_node_corpus_is_pinned() {
    let mut printed = Vec::new();
    let here = env!("CARGO_MANIFEST_DIR");
    let corpus = format!("{here}/tests/vectors/every-node.rs");
    let source = fs::read(&corpus).expect("corpus");
    check(
        "corpus-bytes",
        &String::from_utf8(source).expect("utf-8"),
        "071a28b4fe95bdd55ae986235afef96396607d7f701e8f3d575780da9dd13027",
        &mut printed,
    );
    let out = run(&[&corpus]);
    check(
        "corpus-facts",
        &transcript(&out, here),
        "1c26117b653f0e20628e79b7b0c770acdf961d030b95def76232f67e1d60482b",
        &mut printed,
    );
    finish(printed);
}

#[test]
fn prop_refusals_are_pinned() {
    let vectors = [
        Vector {
            name: "cfg-attr-bare",
            source: Some("#[cfg_attr]\nfn f() {}\n"),
            digest: "6bf504c9c0469c88fc4c29546adb14a1944d61e27916cd59c0c7c8d35eb8795b",
        },
        Vector {
            name: "cfg-attr-empty",
            source: Some("#[cfg_attr()]\nfn f() {}\n"),
            digest: "3655c98dc8dde0167c178c2d40809053c8601d78622258637b35802df1b663d8",
        },
        Vector {
            name: "cfg-attr-unparsable",
            source: Some("#[cfg_attr(creusot, =)]\nfn f() {}\n"),
            digest: "f8d2023856cae235eb64ada0a5e2ed44f79143a2664101cd0f4f06a8afc1fa89",
        },
        Vector {
            name: "not-two",
            source: Some("#[cfg_attr(not(creusot, test), logic)]\nfn f() {}\n"),
            digest: "e0bd30bfd3d2d894fe86fd3d3f8eff4173edc1f4c77e028437ba23ffb5951d10",
        },
        Vector {
            name: "cfg-two",
            source: Some("#[cfg(creusot, test)]\nfn f() {}\n"),
            digest: "f1ff6da1b18273533056f182460abbae4c6246eeb0f10998304dfe60776d8785",
        },
        Vector {
            name: "cfg-bare",
            source: Some("#[cfg]\nfn f() {}\n"),
            digest: "8111e1f17e8446d0cab5534f5f179a4311942167ead157cd206b2ed3987dd895",
        },
        Vector {
            name: "ensures-on-struct",
            source: Some("#[ensures(true)]\nstruct S;\n"),
            digest: "b216827175332b2200c5779f2c01df3e4fe4128acde39c2395ec11171df53438",
        },
        Vector {
            name: "ensures-without-args",
            source: Some("#[ensures]\nfn f() {}\n"),
            digest: "37360e6fe663ad3cd4ad3a9a279e7493519c872508b7f9fd74060f92d1a6cbbd",
        },
        Vector {
            name: "trusted-on-mod",
            source: Some("#[trusted]\nmod m {}\n"),
            digest: "ef82f7ed707ef79cd140ee1c2677d184ee8bd3133cf717c524bddd2a265d1264",
        },
        Vector {
            name: "proof-assert-unknown",
            source: Some("#[cfg(unix)]\nfn f() {\n    proof_assert!(true);\n}\n"),
            digest: "d3d8c7c5d5815a8368110bfb258f237c243a40148c316e762e7b7a12b1947ec3",
        },
        Vector {
            name: "syntax-error",
            source: Some("fn broken(\n"),
            digest: "d49e0bed18c6a10c5fe06132f7aad2bd2ebdfabb6971383ce6484829662060ed",
        },
        Vector {
            name: "missing-file",
            source: None,
            digest: "71b8b77033eabd918240dd312d397508c8b54d8328f1d58ee22088b68bcd65b4",
        },
    ];
    let dir = scratch("refusals");
    let dir_text = dir.to_str().expect("utf-8 dir").to_string();
    let mut printed = Vec::new();
    for vector in &vectors {
        let file = dir.join(format!("{}.rs", vector.name));
        if let Some(source) = vector.source {
            fs::write(&file, source).expect("write vector");
        }
        let out = run(&[file.to_str().expect("utf-8 path")]);
        assert_eq!((out.0, out.1.as_str()), (2, ""), "{}: {out:?}", vector.name);
        check(
            vector.name,
            &transcript(&out, &dir_text),
            vector.digest,
            &mut printed,
        );
    }
    // A later failure discards earlier complete facts.
    let good = dir.join("good.rs");
    fs::write(&good, "#[logic]\nfn f() {}\n").expect("write good");
    let bad = dir.join("syntax-error.rs");
    let out = run(&[good.to_str().expect("utf-8"), bad.to_str().expect("utf-8")]);
    check(
        "partial-is-withheld",
        &transcript(&out, &dir_text),
        "d49e0bed18c6a10c5fe06132f7aad2bd2ebdfabb6971383ce6484829662060ed",
        &mut printed,
    );
    let out = run(&[]);
    check(
        "no-arguments",
        &transcript(&out, &dir_text),
        "9316f99f4a2b094ff073b69dbec3700a594ad10ab7faeb9e491d82f345dd5212",
        &mut printed,
    );
    let tabbed = dir.join("tab\tname.rs");
    let out = run(&[tabbed.to_str().expect("utf-8")]);
    check(
        "control-character",
        &transcript(&out, &dir_text),
        "4deffed4f4bf5f361b01bbe8b82fd547ed789497eab5f7159a82d400356819b0",
        &mut printed,
    );
    let _ = fs::remove_dir_all(dir);
    finish(printed);
}
