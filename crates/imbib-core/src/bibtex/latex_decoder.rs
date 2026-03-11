//! LaTeX character decoding — delegates to the canonical `impress_bibtex` (→ `im-bibtex`) crate.

pub(crate) fn decode_latex_internal(input: String) -> String {
    impress_bibtex::decode_latex(input)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn decode_latex(input: String) -> String {
    decode_latex_internal(input)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_umlaut_decoding() {
        assert_eq!(decode_latex(r#"M\"uller"#.to_string()), "Müller");
        assert_eq!(decode_latex(r#"M\"{u}ller"#.to_string()), "Müller");
    }

    #[test]
    fn test_acute_accent() {
        assert_eq!(decode_latex(r#"caf\'e"#.to_string()), "café");
        assert_eq!(decode_latex(r#"caf\'{e}"#.to_string()), "café");
    }

    #[test]
    fn test_grave_accent() {
        assert_eq!(decode_latex(r#"\`a la carte"#.to_string()), "à la carte");
    }

    #[test]
    fn test_circumflex() {
        assert_eq!(decode_latex(r#"h\^otel"#.to_string()), "hôtel");
    }

    #[test]
    fn test_tilde() {
        assert_eq!(decode_latex(r#"ma\~nana"#.to_string()), "mañana");
    }

    #[test]
    fn test_cedilla() {
        assert_eq!(decode_latex(r#"gar\c con"#.to_string()), "garçon");
    }

    #[test]
    fn test_special_characters() {
        assert_eq!(decode_latex(r#"10\% off"#.to_string()), "10% off");
        assert_eq!(
            decode_latex(r#"Smith \& Jones"#.to_string()),
            "Smith & Jones"
        );
    }

    #[test]
    fn test_dashes() {
        assert_eq!(decode_latex("pages 1--10".to_string()), "pages 1–10");
        assert_eq!(decode_latex("the---as usual".to_string()), "the—as usual");
    }

    #[test]
    fn test_greek_letters() {
        assert_eq!(
            decode_latex(r#"\alpha particles"#.to_string()),
            "α particles"
        );
        assert_eq!(decode_latex(r#"\Gamma function"#.to_string()), "Γ function");
    }

    #[test]
    fn test_math_symbols() {
        assert_eq!(decode_latex(r#"a \times b"#.to_string()), "a × b");
        assert_eq!(decode_latex(r#"a \leq b"#.to_string()), "a ≤ b");
    }

    #[test]
    fn test_tex_command_removal() {
        assert_eq!(decode_latex(r#"\textbf{bold}"#.to_string()), "bold");
        assert_eq!(decode_latex(r#"\emph{italic}"#.to_string()), "italic");
    }

    #[test]
    fn test_brace_cleaning() {
        assert_eq!(decode_latex("{DNA}".to_string()), "{DNA}");
        assert_eq!(decode_latex("{a}".to_string()), "a");
        assert_eq!(decode_latex("test{}".to_string()), "test");
    }

    #[test]
    fn test_complex_example() {
        let input = r#"M\"uller, J. and Garc\'{\i}a, M."#;
        let expected = "Müller, J. and García, M.";
        assert_eq!(decode_latex(input.to_string()), expected);
    }
}
