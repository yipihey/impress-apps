//! Corpus test for [`is_bibcode`] / `BIBCODE_PATTERN`.
//!
//! `test_fixtures/ads_bibcodes.txt` holds 248 bibcodes pulled from live ADS
//! queries (most-cited 2020–2026 refereed papers, plus an ApJL/A&A/PhRvL/MNRAS/
//! arXiv slice), so the recall number below is measured against real data
//! rather than against our own idea of the format.
//!
//! This exists because a pattern with no slot for the bibcode *qualifier*
//! character shipped in Cmd+S and silently rejected 29% of this corpus — every
//! A&A paper, every ApJ/A&A Letter, and every article-ID journal. A rejected
//! identifier does not error; it just falls through to a free-text search that
//! finds nothing, which reads to the user as "the paper isn't in ADS".

use im_identifiers::{extract_bibcode_from_text, is_bibcode};

fn corpus() -> Vec<String> {
    include_str!("../test_fixtures/ads_bibcodes.txt")
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect()
}

/// Deterministic, dependency-free noise generator (LCG) so the false-positive
/// sweep is reproducible across runs and machines.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1);
        self.0 >> 33
    }

    fn pick(&mut self, alphabet: &[u8]) -> char {
        alphabet[(self.next() as usize) % alphabet.len()] as char
    }

    fn token(&mut self, alphabet: &[u8], n: usize) -> String {
        (0..n).map(|_| self.pick(alphabet)).collect()
    }
}

#[test]
fn every_real_bibcode_is_accepted() {
    let corpus = corpus();
    assert_eq!(corpus.len(), 248, "fixture size changed");

    let rejected: Vec<&String> = corpus.iter().filter(|b| !is_bibcode(b)).collect();
    assert!(
        rejected.is_empty(),
        "{} of {} real ADS bibcodes rejected: {:?}",
        rejected.len(),
        corpus.len(),
        rejected
    );
}

#[test]
fn corpus_is_well_formed() {
    for b in corpus() {
        assert_eq!(b.chars().count(), 19, "fixture entry is not 19 chars: {b}");
    }
}

/// The shapes that the pre-fix pattern got wrong, named so a future narrowing
/// of the character classes fails with a description rather than a diff.
#[test]
fn qualifier_slot_accepts_every_real_form() {
    for (bibcode, why) in [
        (
            "2026MNRAS.551g1461W",
            "lowercase issue letter (reported by user)",
        ),
        ("2016PhRvL.116f1102A", "LIGO GW150914 discovery paper"),
        (
            "2020A&A...641A...6P",
            "A&A section letter in the qualifier slot",
        ),
        ("2022ApJ...934L...7R", "ApJ Letters"),
        ("1998A&A...333L..47M", "A&A Letters"),
        (
            "2023arXiv230308774O",
            "arXiv bibcode — digit in the qualifier slot",
        ),
        (
            "2020PTEP.2020h3C01P",
            "PTEP article ID — letter inside the page field",
        ),
        ("2002Sci...295...93a", "lowercase first-author initial"),
        ("2021NucAR..49D.412M", "uppercase qualifier that is not L"),
    ] {
        assert!(is_bibcode(bibcode), "{bibcode} rejected — {why}");
    }
}

#[test]
fn non_bibcodes_are_rejected() {
    for value in [
        "",
        "2026MNRAS.551g1461",   // 18 chars — truncated
        "2026MNRAS.551g1461WX", // 20 chars
        "2026MNRAS.551g1461 W", // embedded space
        "10.1093/mnras/stag1",  // DOI-shaped
        "arXiv:2603.19385v22",
        "1234567890123456789", // all digits
        "AAAAAAAAAAAAAAAAAAA",
        "2020-01-15T00:00:00",
        "dark matter halo sim",
    ] {
        assert!(
            !is_bibcode(value),
            "{value:?} wrongly accepted as a bibcode"
        );
    }
}

/// The journal field must stay letters/`&`/`.` only. Widening it to accept
/// digits is what starts matching hex blobs in scraped HTML, and
/// `url_extract` runs this pattern over whole pages.
#[test]
fn machine_noise_does_not_look_like_a_bibcode() {
    let mut rng = Lcg(0x2026_0907);
    let hex = b"0123456789abcdef";
    let alnum = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

    let mut accepted = Vec::new();
    for _ in 0..4000 {
        for token in [rng.token(hex, 19), rng.token(alnum, 19)] {
            if is_bibcode(&token) {
                accepted.push(token);
            }
        }
        // Year-prefixed noise: the shape closest to a real bibcode.
        let token = format!("20{}{}", rng.token(b"12", 1), rng.token(alnum, 16));
        if is_bibcode(&token) {
            accepted.push(token);
        }
    }
    assert!(
        accepted.is_empty(),
        "{} random tokens accepted as bibcodes, e.g. {:?}",
        accepted.len(),
        &accepted[..accepted.len().min(5)]
    );
}

#[test]
fn extraction_from_text_uses_the_same_shape() {
    assert_eq!(
        extract_bibcode_from_text("see 2026MNRAS.551g1461W for details".into()),
        Some("2026MNRAS.551g1461W".to_string())
    );
    assert_eq!(
        extract_bibcode_from_text("the Letter 2022ApJ...934L...7R argues".into()),
        Some("2022ApJ...934L...7R".to_string())
    );
    assert_eq!(extract_bibcode_from_text("no identifier here".into()), None);
}
