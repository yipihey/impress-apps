//! Abstracts as plain text for a frontend with no math renderer (koine-web,
//! the TUI, a list row).
//!
//! [`parse_abstract`] already splits an abstract into prose and math. Each
//! inline math segment becomes Unicode when every part of it has a Unicode
//! form — `$\sim$40` reads `∼40`, `deg$^{-2}$` reads `deg⁻²`, `H$_2$` reads
//! `H₂`, `$M_\odot$` reads `M⊙` — and stays as written, in a markdown code
//! span, when any part does not. A half-converted formula is worse than the
//! TeX a researcher reads anyway, so there is no partial result.

use super::abstract_parser::{parse_abstract, AbstractSegment};

/// The abstract with its math as Unicode where it converts whole, and as a
/// code span where it does not. Prose is passed through unchanged.
pub fn abstract_display_text(text: &str) -> String {
    let mut out = String::new();
    for segment in parse_abstract(text) {
        match segment {
            AbstractSegment::Text(t) => out.push_str(&t),
            AbstractSegment::InlineMath(m) | AbstractSegment::DisplayMath(m) => {
                match inline_math_to_unicode(&m) {
                    Some(u) => out.push_str(&u),
                    None => {
                        out.push('`');
                        out.push_str(m.trim());
                        out.push('`');
                    }
                }
            }
        }
    }
    out
}

/// One formula as Unicode, or `None` when any command, script or group in it
/// has no Unicode form.
pub fn inline_math_to_unicode(latex: &str) -> Option<String> {
    let chars: Vec<char> = latex.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        match c {
            '\\' => {
                let (name, next) = command(&chars, i + 1);
                i = next;
                match name.as_str() {
                    // Fonts and spacing: the argument (or nothing) as is.
                    "rm" | "mathrm" | "textrm" | "text" | "mathit" | "it" | "mathbf" | "bf"
                    | "mathsf" | "operatorname" => {
                        if chars.get(i) == Some(&'{') {
                            let (inner, after) = group(&chars, i)?;
                            out.push_str(&inline_math_to_unicode(&inner)?);
                            i = after;
                        }
                    }
                    "," | ";" | ":" | " " | "!" | "quad" | "qquad" => out.push(' '),
                    "left" | "right" | "big" | "Big" => {}
                    other => out.push_str(symbol(other)?),
                }
            }
            '^' | '_' => {
                let (arg, next) = script_argument(&chars, i + 1)?;
                i = next;
                let converted = inline_math_to_unicode(&arg)?;
                for ch in converted.chars() {
                    out.push(if c == '^' {
                        superscript(ch)?
                    } else {
                        subscript(ch)?
                    });
                }
            }
            '{' | '}' => i += 1,
            '~' => {
                out.push(' ');
                i += 1;
            }
            _ => {
                out.push(c);
                i += 1;
            }
        }
    }
    Some(out)
}

/// The command name after a backslash: letters, or one non-letter.
fn command(chars: &[char], start: usize) -> (String, usize) {
    let mut end = start;
    while end < chars.len() && chars[end].is_ascii_alphabetic() {
        end += 1;
    }
    if end == start && start < chars.len() {
        end = start + 1;
    }
    let name: String = chars[start..end].iter().collect();
    // A space after a letter command only ends it.
    let mut next = end;
    if name.chars().all(|c| c.is_ascii_alphabetic()) {
        while next < chars.len() && chars[next] == ' ' {
            next += 1;
        }
    }
    (name, next)
}

/// The contents of a `{…}` group at `start`, and the index after it.
fn group(chars: &[char], start: usize) -> Option<(String, usize)> {
    let mut depth = 0;
    for (k, &c) in chars.iter().enumerate().skip(start) {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some((chars[start + 1..k].iter().collect(), k + 1));
                }
            }
            _ => {}
        }
    }
    None
}

/// A script's argument: a group, a command, or one character.
fn script_argument(chars: &[char], start: usize) -> Option<(String, usize)> {
    match chars.get(start)? {
        '{' => group(chars, start),
        '\\' => {
            let (name, next) = command(chars, start + 1);
            Some((format!("\\{name}"), next))
        }
        c => Some((c.to_string(), start + 1)),
    }
}

fn symbol(name: &str) -> Option<&'static str> {
    Some(match name {
        "alpha" => "α",
        "beta" => "β",
        "gamma" => "γ",
        "delta" => "δ",
        "epsilon" | "varepsilon" => "ε",
        "zeta" => "ζ",
        "eta" => "η",
        "theta" | "vartheta" => "θ",
        "iota" => "ι",
        "kappa" => "κ",
        "lambda" => "λ",
        "mu" => "μ",
        "nu" => "ν",
        "xi" => "ξ",
        "pi" => "π",
        "rho" => "ρ",
        "sigma" => "σ",
        "tau" => "τ",
        "upsilon" => "υ",
        "phi" | "varphi" => "φ",
        "chi" => "χ",
        "psi" => "ψ",
        "omega" => "ω",
        "Gamma" => "Γ",
        "Delta" => "Δ",
        "Theta" => "Θ",
        "Lambda" => "Λ",
        "Xi" => "Ξ",
        "Pi" => "Π",
        "Sigma" => "Σ",
        "Phi" => "Φ",
        "Psi" => "Ψ",
        "Omega" => "Ω",
        "sim" => "∼",
        "simeq" => "≃",
        "approx" => "≈",
        "propto" => "∝",
        "lesssim" | "la" | "lsim" => "≲",
        "gtrsim" | "ga" | "gsim" => "≳",
        "le" | "leq" => "≤",
        "ge" | "geq" => "≥",
        "ll" => "≪",
        "gg" => "≫",
        "ne" | "neq" => "≠",
        "equiv" => "≡",
        "pm" => "±",
        "mp" => "∓",
        "times" => "×",
        "cdot" => "·",
        "div" => "÷",
        "infty" => "∞",
        "odot" | "sun" => "⊙",
        "oplus" => "⊕",
        "earth" => "⊕",
        "prime" => "′",
        "circ" => "∘",
        "degree" => "°",
        "deg" => "°",
        "partial" => "∂",
        "nabla" => "∇",
        "sum" => "∑",
        "int" => "∫",
        "sqrt" => "√",
        "langle" => "⟨",
        "rangle" => "⟩",
        "rightarrow" | "to" => "→",
        "leftarrow" => "←",
        "leftrightarrow" => "↔",
        "Rightarrow" => "⇒",
        "hbar" => "ℏ",
        "ell" => "ℓ",
        "AA" | "angstrom" => "Å",
        "%" => "%",
        "$" => "$",
        "&" => "&",
        "#" => "#",
        "_" => "_",
        "{" => "{",
        "}" => "}",
        _ => return None,
    })
}

fn superscript(c: char) -> Option<char> {
    Some(match c {
        '0' => '⁰',
        '1' => '¹',
        '2' => '²',
        '3' => '³',
        '4' => '⁴',
        '5' => '⁵',
        '6' => '⁶',
        '7' => '⁷',
        '8' => '⁸',
        '9' => '⁹',
        '+' => '⁺',
        '-' | '−' => '⁻',
        '=' => '⁼',
        '(' => '⁽',
        ')' => '⁾',
        'n' => 'ⁿ',
        'i' => 'ⁱ',
        ' ' => ' ',
        '∘' | '°' => '°',
        '′' => '′',
        _ => return None,
    })
}

fn subscript(c: char) -> Option<char> {
    Some(match c {
        '0' => '₀',
        '1' => '₁',
        '2' => '₂',
        '3' => '₃',
        '4' => '₄',
        '5' => '₅',
        '6' => '₆',
        '7' => '₇',
        '8' => '₈',
        '9' => '₉',
        '+' => '₊',
        '-' | '−' => '₋',
        '=' => '₌',
        '(' => '₍',
        ')' => '₎',
        'a' => 'ₐ',
        'e' => 'ₑ',
        'o' => 'ₒ',
        'x' => 'ₓ',
        'h' => 'ₕ',
        'k' => 'ₖ',
        'l' => 'ₗ',
        'm' => 'ₘ',
        'n' => 'ₙ',
        'p' => 'ₚ',
        's' => 'ₛ',
        't' => 'ₜ',
        'i' => 'ᵢ',
        'r' => 'ᵣ',
        'u' => 'ᵤ',
        'v' => 'ᵥ',
        'j' => 'ⱼ',
        '⊙' => '⊙',
        ' ' => ' ',
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn common_astrophysics_math_reads_as_unicode() {
        assert_eq!(inline_math_to_unicode(r"\sim").as_deref(), Some("∼"));
        assert_eq!(inline_math_to_unicode(r"^{-2}").as_deref(), Some("⁻²"));
        assert_eq!(inline_math_to_unicode(r"_2").as_deref(), Some("₂"));
        assert_eq!(inline_math_to_unicode(r"M_\odot").as_deref(), Some("M⊙"));
        assert_eq!(inline_math_to_unicode(r"10^{5}").as_deref(), Some("10⁵"));
        assert_eq!(inline_math_to_unicode(r"\alpha").as_deref(), Some("α"));
        assert_eq!(
            inline_math_to_unicode(r"z\gtrsim 6").as_deref(),
            Some("z≳6")
        );
        assert_eq!(
            inline_math_to_unicode(r"1.5\,{\rm rad\,m^{-2}}").as_deref(),
            Some("1.5 rad m⁻²")
        );
    }

    #[test]
    fn what_has_no_unicode_form_is_not_half_converted() {
        assert_eq!(inline_math_to_unicode(r"\frac{a}{b}"), None);
        assert_eq!(inline_math_to_unicode(r"x^{y}"), None, "no superscript y");
        assert_eq!(inline_math_to_unicode(r"\mathcal{L}"), None);
    }

    #[test]
    fn an_abstract_keeps_its_prose_and_converts_or_quotes_its_math() {
        assert_eq!(
            abstract_display_text(r"densities of $\sim$40 sources deg$^{-2}$ and H$_2$"),
            "densities of ∼40 sources deg⁻² and H₂"
        );
        assert_eq!(
            abstract_display_text(r"a ratio $\frac{a}{b}$ here"),
            "a ratio `\\frac{a}{b}` here"
        );
    }
}
