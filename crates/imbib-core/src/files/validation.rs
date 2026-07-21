//! Pure-byte PDF validation rules.
//!
//! These mirror the health-check intent of Swift's `PDFHealthCheckService.swift`
//! and the byte-level sanity checks the file-import path performs in
//! `PDFManager.swift` (magic-byte sniffing in `detectFromMagicBytes`, EOF
//! checks, page-count vs file-size sanity).
//!
//! The Swift service that *also* lives at that filename — `PDFHealthCheckService`
//! — is really about cross-library file *location* sync (an action that
//! requires `FileManager`), so it is intentionally NOT ported here. See the
//! TODO at the bottom of this file referencing
//! `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Files/PDFHealthCheckService.swift:85`.
//!
//! Per the plan: file I/O stays in Swift; this module operates on bytes only.

/// Severity classification for a validation finding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValidationSeverity {
    /// Worth surfacing in the console but the file is still usable.
    Info,
    /// File likely renderable but suspicious (e.g. unusually small for the
    /// declared page count). UI should hint at the issue.
    Warning,
    /// File is structurally broken: missing `%PDF-` header, missing EOF
    /// marker, or zero bytes. Should block import.
    Error,
}

/// A single validation finding produced by `validate_pdf`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidationIssue {
    pub severity: ValidationSeverity,
    /// Machine-readable identifier — stable across versions so callers can
    /// pattern-match without parsing the human message.
    pub code: &'static str,
    pub message: String,
}

impl ValidationIssue {
    fn error(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            severity: ValidationSeverity::Error,
            code,
            message: message.into(),
        }
    }

    fn warning(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            severity: ValidationSeverity::Warning,
            code,
            message: message.into(),
        }
    }

    fn info(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            severity: ValidationSeverity::Info,
            code,
            message: message.into(),
        }
    }
}

/// Validate PDF bytes. Returns all findings (empty Vec = file passes).
///
/// Checks performed (Swift-parallel comments in each branch):
///
/// 1. Non-empty (Swift `AttachmentError.emptyDownload`).
/// 2. `%PDF-` magic header (Swift `detectFromMagicBytes` in PDFManager.swift).
/// 3. Recognized PDF version string after `%PDF-` (1.x or 2.x).
/// 4. `%%EOF` end-of-file marker within the last 1024 bytes (per PDF spec
///    §7.5.5; matches the leniency Adobe / pdfium also apply).
/// 5. Rough page count vs file size: extracts `/Type /Page` (not `/Pages`)
///    occurrences from the raw byte stream and compares against an absolute
///    minimum-per-page floor of 100 bytes. This is a cheap sanity check, not
///    a true parser. Returns a Warning, not an Error, because content streams
///    can legitimately be tiny (blank pages).
pub fn validate_pdf(bytes: &[u8]) -> Vec<ValidationIssue> {
    let mut issues = Vec::new();

    // 1. Empty
    if bytes.is_empty() {
        issues.push(ValidationIssue::error("empty", "PDF is zero bytes"));
        return issues;
    }

    // 2. Header magic
    if !bytes.starts_with(b"%PDF-") {
        issues.push(ValidationIssue::error(
            "missing_header",
            format!(
                "missing %PDF- header (first 8 bytes: {:?})",
                &bytes[..bytes.len().min(8)]
            ),
        ));
        // Return early — every subsequent check assumes a valid header.
        return issues;
    }

    // 3. Version after %PDF-
    if let Some(version_byte) = bytes.get(5) {
        let major = *version_byte;
        // Allow 1.x and 2.x; anything else is suspicious.
        if major != b'1' && major != b'2' {
            issues.push(ValidationIssue::warning(
                "unknown_version",
                format!("unexpected PDF version major: {:?}", char::from(major)),
            ));
        }
    } else {
        issues.push(ValidationIssue::error(
            "truncated_header",
            "file ends inside the %PDF- header",
        ));
        return issues;
    }

    // 4. %%EOF within the last 1024 bytes.
    let tail_start = bytes.len().saturating_sub(1024);
    let tail = &bytes[tail_start..];
    if !contains_subslice(tail, b"%%EOF") {
        issues.push(ValidationIssue::error(
            "missing_eof",
            "no %%EOF marker in the last 1024 bytes — file likely truncated",
        ));
    }

    // 5. Page count vs file size sanity. We do a byte-level scan for
    //    "/Type /Page" (with optional whitespace between) but exclude
    //    "/Type /Pages" (the page-tree node).
    let approx_pages = approximate_page_count(bytes);
    if let Some(avg_bytes_per_page) = bytes.len().checked_div(approx_pages) {
        // PDF page objects are tiny (<100 B) by themselves but the content
        // stream they reference is typically much larger. Pick a generous
        // floor so this only flags wildly-out-of-bound files.
        if avg_bytes_per_page < 100 {
            issues.push(ValidationIssue::warning(
                "page_size_anomaly",
                format!(
                    "average {} bytes/page across {} pages — file may be truncated or corrupt",
                    avg_bytes_per_page, approx_pages
                ),
            ));
        }
    } else {
        issues.push(ValidationIssue::info(
            "no_pages_detected",
            "no `/Type /Page` objects found via byte scan (encrypted, FDF, or stub PDF)",
        ));
    }

    issues
}

/// Approximate page count via byte-level scan. Counts `/Type /Page` (but not
/// `/Type /Pages`) occurrences. Not a parser — adequate for sanity-check
/// purposes per the migration plan ("page count vs size sanity").
///
/// TODO: replace with `crate::pdf::get_page_count` once the validation entry
/// point is plumbed through the FFI; that one uses pdfium-render and is
/// authoritative. See `apps/imbib/.../Files/PDFHealthCheckService.swift:85`
/// for the equivalent Swift call site (currently uses location-sync logic,
/// not byte sanity).
fn approximate_page_count(bytes: &[u8]) -> usize {
    let needle = b"/Type";
    let mut count = 0;
    let mut i = 0;
    while i + needle.len() < bytes.len() {
        if &bytes[i..i + needle.len()] == needle {
            // Skip whitespace
            let mut j = i + needle.len();
            while j < bytes.len()
                && (bytes[j] == b' ' || bytes[j] == b'\t' || bytes[j] == b'\r' || bytes[j] == b'\n')
            {
                j += 1;
            }
            // Expect "/Page" next
            if j + 5 <= bytes.len() && &bytes[j..j + 5] == b"/Page" {
                // Distinguish /Page from /Pages by inspecting the byte right after.
                let after = bytes.get(j + 5);
                let is_pages = matches!(after, Some(b's'));
                if !is_pages {
                    count += 1;
                }
            }
            i = j;
        } else {
            i += 1;
        }
    }
    count
}

fn contains_subslice(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || haystack.len() < needle.len() {
        return needle.is_empty();
    }
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Smallest legal-ish PDF that should pass header + EOF checks. Single
    /// catalog/pages/page tree; ~500 bytes. Real-world tiny but valid.
    fn minimal_pdf() -> Vec<u8> {
        // Hand-written tiny PDF.
        let pdf = b"%PDF-1.4\n\
1 0 obj<</Type /Catalog /Pages 2 0 R>>endobj\n\
2 0 obj<</Type /Pages /Kids [3 0 R] /Count 1>>endobj\n\
3 0 obj<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R>>endobj\n\
4 0 obj<</Length 44>>stream\n\
BT /F1 12 Tf 100 700 Td (Hello, World!) Tj ET\n\
endstream endobj\n\
xref\n\
0 5\n\
0000000000 65535 f \n\
0000000009 00000 n \n\
0000000058 00000 n \n\
0000000115 00000 n \n\
0000000198 00000 n \n\
trailer<</Size 5 /Root 1 0 R>>\n\
startxref\n\
277\n\
%%EOF\n";
        // Pad to >100 bytes/page so size-vs-page sanity passes (single page,
        // so we need >=100 bytes total — pdf above is comfortably larger).
        pdf.to_vec()
    }

    #[test]
    fn passes_minimal_valid_pdf() {
        let issues = validate_pdf(&minimal_pdf());
        // No errors should be reported.
        for issue in &issues {
            assert_ne!(
                issue.severity,
                ValidationSeverity::Error,
                "unexpected error: {:?}",
                issue
            );
        }
    }

    #[test]
    fn rejects_empty() {
        let issues = validate_pdf(&[]);
        assert_eq!(issues.len(), 1);
        assert_eq!(issues[0].code, "empty");
        assert_eq!(issues[0].severity, ValidationSeverity::Error);
    }

    #[test]
    fn rejects_missing_header() {
        let bytes = b"this is not a pdf";
        let issues = validate_pdf(bytes);
        assert!(issues
            .iter()
            .any(|i| i.code == "missing_header" && i.severity == ValidationSeverity::Error));
    }

    #[test]
    fn rejects_truncated_no_eof() {
        // %PDF- header + version, but no %%EOF anywhere.
        let mut bytes = b"%PDF-1.4\n".to_vec();
        // Pad with junk that does NOT contain %%EOF.
        bytes.extend(std::iter::repeat_n(b'X', 2000));
        let issues = validate_pdf(&bytes);
        assert!(issues.iter().any(|i| i.code == "missing_eof"));
    }

    #[test]
    fn warns_unknown_version() {
        // %PDF-9.x is not a real version.
        let mut bytes = b"%PDF-9.0\n".to_vec();
        bytes.extend_from_slice(b"%%EOF\n");
        let issues = validate_pdf(&bytes);
        assert!(issues
            .iter()
            .any(|i| i.code == "unknown_version" && i.severity == ValidationSeverity::Warning));
    }

    #[test]
    fn distinguishes_page_from_pages() {
        // 1 `/Type /Page` and 1 `/Type /Pages` — counter should report 1 not 2.
        let bytes = b"%PDF-1.4\n\
1 0 obj<</Type /Pages /Count 1>>endobj\n\
2 0 obj<</Type /Page /Parent 1 0 R>>endobj\n\
some padding to keep avg page size above 100 bytes per page so the sanity warning does not trip on this otherwise minimal test fixture file content here\n\
%%EOF\n";
        let n = approximate_page_count(bytes);
        assert_eq!(n, 1, "should count 1 Page (not Pages)");
        // No error- or warning-level issues expected for this synthetic PDF.
        let issues = validate_pdf(bytes);
        assert!(
            !issues
                .iter()
                .any(|i| i.severity == ValidationSeverity::Error),
            "unexpected errors: {:?}",
            issues
        );
    }

    #[test]
    fn page_count_anomaly_triggers_warning() {
        // Many pages claimed in a very small file.
        let mut bytes = b"%PDF-1.4\n".to_vec();
        for _ in 0..50 {
            bytes.extend_from_slice(b"<</Type /Page>>");
        }
        bytes.extend_from_slice(b"\n%%EOF\n");
        let issues = validate_pdf(&bytes);
        // 50 pages in <2KB → <100 bytes/page → warning.
        assert!(
            issues.iter().any(|i| i.code == "page_size_anomaly"),
            "expected size anomaly warning, got: {:?}",
            issues
        );
    }

    #[test]
    fn info_when_no_pages_detected() {
        // Valid header + EOF but no page objects (e.g., encrypted or stub).
        let bytes = b"%PDF-1.7\n\
1 0 obj<</Type /Catalog>>endobj\n\
%%EOF\n";
        let issues = validate_pdf(bytes);
        assert!(issues
            .iter()
            .any(|i| i.code == "no_pages_detected" && i.severity == ValidationSeverity::Info));
    }

    #[test]
    fn truncated_header_reports_error() {
        let bytes = b"%PDF-"; // only 5 bytes — version byte missing
        let issues = validate_pdf(bytes);
        assert!(issues.iter().any(|i| i.code == "truncated_header"));
    }
}
