//! Journal macro expansion — delegates to the canonical `impress_bibtex` (→ `im-bibtex`) crate.

pub(crate) fn expand_journal_macro_internal(value: String) -> String {
    impress_bibtex::expand_journal_macro(value)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn expand_journal_macro(value: String) -> String {
    expand_journal_macro_internal(value)
}

pub(crate) fn is_journal_macro_internal(value: String) -> bool {
    impress_bibtex::is_journal_macro(value)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_journal_macro(value: String) -> bool {
    is_journal_macro_internal(value)
}

pub(crate) fn get_all_journal_macro_names_internal() -> Vec<String> {
    impress_bibtex::get_all_journal_macro_names()
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn get_all_journal_macro_names() -> Vec<String> {
    get_all_journal_macro_names_internal()
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
        assert_eq!(
            expand_journal_macro("mnras".to_string()),
            "Monthly Notices of the Royal Astronomical Society"
        );
    }

    #[test]
    fn test_expand_case_insensitive() {
        assert_eq!(
            expand_journal_macro("APJ".to_string()),
            "Astrophysical Journal"
        );
        assert_eq!(
            expand_journal_macro("\\APJ".to_string()),
            "Astrophysical Journal"
        );
    }

    #[test]
    fn test_expand_unknown_returns_original() {
        assert_eq!(
            expand_journal_macro("Nature Physics".to_string()),
            "Nature Physics"
        );
        assert_eq!(expand_journal_macro("\\unknown".to_string()), "\\unknown");
    }

    #[test]
    fn test_expand_with_whitespace() {
        assert_eq!(
            expand_journal_macro("  apj  ".to_string()),
            "Astrophysical Journal"
        );
    }

    #[test]
    fn test_is_macro() {
        assert!(is_journal_macro("apj".to_string()));
        assert!(is_journal_macro("\\apj".to_string()));
        assert!(is_journal_macro("MNRAS".to_string()));
        assert!(!is_journal_macro("Nature".to_string()));
        assert!(!is_journal_macro("\\unknown".to_string()));
    }

    #[test]
    fn test_get_all_macro_names() {
        let names = get_all_journal_macro_names();
        assert!(names.len() > 50);
        assert!(names.contains(&"apj".to_string()));
    }
}
