//! `imprint-selftest` — run imprint's capability self-tests and print a report.
//!
//! Usage:
//!   imprint-selftest                 # Tier A + Tier B (localhost:23121)
//!   imprint-selftest --tier a        # Tier A only (pure Rust, no app)
//!   imprint-selftest --tier b        # Tier B only (needs running app)
//!   imprint-selftest --json          # machine-readable report
//!   imprint-selftest --url http://127.0.0.1:23121
//!
//! Exit code is non-zero if any capability failed (skips don't count).

use imprint_selftest::{run_all, run_tier_a, run_tier_b, SelfTestReport, Tier, DEFAULT_BASE_URL};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();

    let json = args.iter().any(|a| a == "--json");
    let tier = arg_value(&args, "--tier").map(|s| s.to_ascii_lowercase());
    let url = arg_value(&args, "--url")
        .map(str::to_string)
        .unwrap_or_else(|| DEFAULT_BASE_URL.to_string());

    let report = match tier.as_deref() {
        Some("a") => run_tier_a().await,
        Some("b") => run_tier_b(&url).await,
        _ => run_all(&url).await,
    };

    if json {
        println!("{}", serde_json::to_string_pretty(&report).unwrap());
    } else {
        print_human(&report);
    }

    if !report.ok() {
        std::process::exit(1);
    }
}

fn arg_value<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1))
        .map(|s| s.as_str())
}

fn print_human(report: &SelfTestReport) {
    for r in &report.results {
        let tier = match r.tier {
            Tier::A => "A",
            Tier::B => "B",
        };
        let mark = if r.skipped {
            "skip"
        } else if r.pass {
            " ok "
        } else {
            "FAIL"
        };
        println!(
            "[{mark}] ({tier}) {:<36} {}  — {}",
            r.id,
            fmt_ms(r.duration_ms),
            r.detail
        );
    }
    println!("\n{}", report.summary());
}

fn fmt_ms(ms: u64) -> String {
    format!("{ms:>4}ms")
}
