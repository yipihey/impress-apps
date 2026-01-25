//! Journal macro expansion
//!
//! Expands AASTeX journal macro abbreviations to full journal names.

use lazy_static::lazy_static;
use std::collections::HashMap;

lazy_static! {
    /// Dictionary mapping journal macros to full names.
    static ref MACROS: HashMap<&'static str, &'static str> = {
        let mut m = HashMap::new();

        // Major Astronomical Journals
        m.insert("aj", "Astronomical Journal");
        m.insert("apj", "Astrophysical Journal");
        m.insert("apjl", "Astrophysical Journal, Letters");
        m.insert("apjlett", "Astrophysical Journal, Letters");
        m.insert("apjs", "Astrophysical Journal, Supplement");
        m.insert("apjsupp", "Astrophysical Journal, Supplement");
        m.insert("mnras", "Monthly Notices of the Royal Astronomical Society");
        m.insert("aap", "Astronomy and Astrophysics");
        m.insert("astap", "Astronomy and Astrophysics");
        m.insert("aaps", "Astronomy and Astrophysics, Supplement");
        m.insert("pasp", "Publications of the Astronomical Society of the Pacific");
        m.insert("pasj", "Publications of the Astronomical Society of Japan");
        m.insert("pasa", "Publications of the Astronomical Society of Australia");

        // Review Journals
        m.insert("araa", "Annual Review of Astronomy and Astrophysics");
        m.insert("aapr", "Astronomy and Astrophysics Reviews");

        // Society Publications
        m.insert("baas", "Bulletin of the American Astronomical Society");
        m.insert("memras", "Memoirs of the Royal Astronomical Society");
        m.insert("qjras", "Quarterly Journal of the Royal Astronomical Society");
        m.insert("jrasc", "Journal of the Royal Astronomical Society of Canada");
        m.insert("memsai", "Memorie della Societa Astronomica Italiana");
        m.insert("iaucirc", "IAU Circulars");

        // Specialized Fields
        m.insert("icarus", "Icarus");
        m.insert("psj", "Planetary Science Journal");
        m.insert("solphys", "Solar Physics");
        m.insert("jcap", "Journal of Cosmology and Astroparticle Physics");
        m.insert("planss", "Planetary and Space Science");
        m.insert("grl", "Geophysical Research Letters");
        m.insert("jgr", "Journal of Geophysical Research");

        // Physics Journals
        m.insert("prl", "Physical Review Letters");
        m.insert("pra", "Physical Review A");
        m.insert("prb", "Physical Review B");
        m.insert("prc", "Physical Review C");
        m.insert("prd", "Physical Review D");
        m.insert("pre", "Physical Review E");
        m.insert("physrep", "Physics Reports");
        m.insert("physscr", "Physica Scripta");
        m.insert("nphysa", "Nuclear Physics A");

        // Optics and Spectroscopy
        m.insert("ao", "Applied Optics");
        m.insert("applopt", "Applied Optics");
        m.insert("jqsrt", "Journal of Quantitative Spectroscopy and Radiative Transfer");
        m.insert("procspie", "Proceedings of the SPIE");

        // General Science
        m.insert("nat", "Nature");
        m.insert("sci", "Science");
        m.insert("ssr", "Space Science Reviews");
        m.insert("apss", "Astrophysics and Space Science");

        // Regional Journals
        m.insert("actaa", "Acta Astronomica");
        m.insert("azh", "Astronomicheskii Zhurnal");
        m.insert("sovast", "Soviet Astronomy");
        m.insert("caa", "Chinese Astronomy and Astrophysics");
        m.insert("cjaa", "Chinese Journal of Astronomy and Astrophysics");
        m.insert("rmxaa", "Revista Mexicana de Astronomia y Astrofisica");
        m.insert("bac", "Bulletin of the Astronomical Institutes of Czechoslovakia");
        m.insert("bain", "Bulletin Astronomical Institute of the Netherlands");
        m.insert("zap", "Zeitschrift fuer Astrophysik");

        // Other
        m.insert("na", "New Astronomy");
        m.insert("nar", "New Astronomy Review");
        m.insert("skytel", "Sky & Telescope");
        m.insert("aplett", "Astrophysics Letters");
        m.insert("apspr", "Astrophysics Space Physics Research");
        m.insert("fcp", "Fundamental Cosmic Physics");
        m.insert("gca", "Geochimica et Cosmochimica Acta");
        m.insert("jcp", "Journal of Chemical Physics");

        m
    };
}

/// Expand a journal macro to its full name
pub fn expand_journal_macro(value: String) -> String {
    let trimmed = value.trim();

    // Check for LaTeX macro format: \apj
    if let Some(stripped) = trimmed.strip_prefix('\\') {
        let macro_name = stripped.to_lowercase();
        if let Some(&full_name) = MACROS.get(macro_name.as_str()) {
            return full_name.to_string();
        }
    }

    // Check for bare macro name
    let lowercased = trimmed.to_lowercase();
    if let Some(&full_name) = MACROS.get(lowercased.as_str()) {
        return full_name.to_string();
    }

    // Not a macro - return original
    value
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn expand_journal_macro_ffi(value: String) -> String {
    expand_journal_macro(value)
}

/// Check if a value is a journal macro
pub fn is_journal_macro(value: String) -> bool {
    let trimmed = value.trim();

    // Check LaTeX format
    if let Some(stripped) = trimmed.strip_prefix('\\') {
        let macro_name = stripped.to_lowercase();
        return MACROS.contains_key(macro_name.as_str());
    }

    // Check bare format
    MACROS.contains_key(trimmed.to_lowercase().as_str())
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn is_journal_macro_ffi(value: String) -> bool {
    is_journal_macro(value)
}

/// Get all journal macro names
pub fn get_all_journal_macro_names() -> Vec<String> {
    MACROS.keys().map(|k| k.to_string()).collect()
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn get_all_journal_macro_names_ffi() -> Vec<String> {
    get_all_journal_macro_names()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_expand_latex_format() {
        assert_eq!(
            expand_journal_macro("\\apj".to_string()),
            "Astrophysical Journal"
        );
        assert_eq!(
            expand_journal_macro("\\mnras".to_string()),
            "Monthly Notices of the Royal Astronomical Society"
        );
    }

    #[test]
    fn test_expand_bare_format() {
        assert_eq!(
            expand_journal_macro("apj".to_string()),
            "Astrophysical Journal"
        );
    }

    #[test]
    fn test_expand_case_insensitive() {
        assert_eq!(
            expand_journal_macro("APJ".to_string()),
            "Astrophysical Journal"
        );
    }

    #[test]
    fn test_expand_unknown_returns_original() {
        assert_eq!(
            expand_journal_macro("Nature Physics".to_string()),
            "Nature Physics"
        );
    }

    #[test]
    fn test_is_macro() {
        assert!(is_journal_macro("apj".to_string()));
        assert!(is_journal_macro("\\apj".to_string()));
        assert!(!is_journal_macro("Nature".to_string()));
    }

    #[test]
    fn test_get_all_macro_names() {
        let names = get_all_journal_macro_names();
        assert!(names.len() > 50);
        assert!(names.contains(&"apj".to_string()));
    }
}
