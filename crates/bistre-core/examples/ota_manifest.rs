//! Release tool for the OTA manifest v2 (Spec 10): written and checked with the same
//! types the app reads.
//!
//! - `build <dist> <tag> <repo> [notes_file]`: writes `<dist>/manifest.json`.
//! - `verify <dist> <pubkey_b64>`: verifies `<dist>/manifest.json(.minisig)`, parses it with
//!   the app's parser, and checks every listed file's digest and size. Fails closed.

use std::path::Path;
use std::process::ExitCode;

use bistre_core::ota_manifest::{build_release_manifest, verify_release_dir};

#[expect(
    clippy::print_stderr,
    reason = "release CLI reports the diagnostic key of a failure to the CI log"
)]
fn fail(what: &str, err: &dyn std::fmt::Display) -> ExitCode {
    eprintln!("ota_manifest {what} failed: {err}");
    ExitCode::FAILURE
}

#[expect(
    clippy::print_stdout,
    reason = "release CLI prints one confirmation line to the CI log"
)]
fn done(line: &str) -> ExitCode {
    println!("{line}");
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        ["build", dist, tag, repo, rest @ ..] => {
            let notes = match rest.first() {
                Some(path) => match std::fs::read_to_string(path) {
                    Ok(text) => text,
                    Err(err) => return fail("build", &err),
                },
                None => String::new(),
            };
            let manifest = match build_release_manifest(
                Path::new(dist),
                tag,
                bistre_core::CORE_VERSION,
                repo,
                &notes,
            ) {
                Ok(m) => m,
                Err(err) => return fail("build", &err),
            };
            let json = match serde_json::to_string_pretty(&manifest) {
                Ok(j) => j,
                Err(err) => return fail("build", &err),
            };
            if let Err(err) = std::fs::write(Path::new(dist).join("manifest.json"), json + "\n") {
                return fail("build", &err);
            }
            done(&format!("manifest.json written for {tag}"))
        }
        ["verify", dist, pubkey] => {
            let dir = Path::new(dist);
            let bytes = match std::fs::read(dir.join("manifest.json")) {
                Ok(b) => b,
                Err(err) => return fail("verify", &err),
            };
            let sig = match std::fs::read_to_string(dir.join("manifest.json.minisig")) {
                Ok(s) => s,
                Err(err) => return fail("verify", &err),
            };
            match verify_release_dir(dir, &bytes, &sig, pubkey) {
                Ok(m) => done(&format!(
                    "VERIFIED {} ({} targets)",
                    m.semver,
                    m.targets.len()
                )),
                Err(err) => fail("verify", &err),
            }
        }
        _ => fail(
            "usage",
            &"build <dist> <tag> <repo> [notes_file] | verify <dist> <pubkey_b64>",
        ),
    }
}
