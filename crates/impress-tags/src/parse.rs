//! Tag input parsing.

/// Parse a tag path input, normalizing separators and whitespace.
///
/// - Trims whitespace
/// - Replaces backslashes with forward slashes
/// - Removes leading/trailing slashes
/// - Collapses multiple slashes
///
/// # Examples
/// ```
/// use impress_tags::parse_tag_path;
/// assert_eq!(parse_tag_path("  methods/sims/hydro  "), Some("methods/sims/hydro".to_string()));
/// assert_eq!(parse_tag_path("methods\\sims"), Some("methods/sims".to_string()));
/// assert_eq!(parse_tag_path(""), None);
/// ```
#[cfg_attr(feature = "native", uniffi::export)]
pub fn parse_tag_path(input: &str) -> Option<String> {
    let normalized = input
        .trim()
        .replace('\\', "/");

    let segments: Vec<&str> = normalized
        .split('/')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();

    if segments.is_empty() {
        return None;
    }

    Some(segments.join("/"))
}

/// Extract the leaf (last segment) from a tag path.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn tag_leaf(path: &str) -> String {
    path.rsplit('/').next().unwrap_or(path).to_string()
}

/// Extract the parent path (everything before the last segment).
#[cfg_attr(feature = "native", uniffi::export)]
pub fn tag_parent(path: &str) -> Option<String> {
    path.rfind('/').map(|i| path[..i].to_string())
}

/// Count the depth of a tag path (number of separators).
#[cfg_attr(feature = "native", uniffi::export)]
pub fn tag_depth(path: &str) -> u32 {
    path.matches('/').count() as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_normal() {
        assert_eq!(parse_tag_path("methods/sims/hydro"), Some("methods/sims/hydro".to_string()));
    }

    #[test]
    fn parse_with_whitespace() {
        assert_eq!(parse_tag_path("  methods / sims  "), Some("methods/sims".to_string()));
    }

    #[test]
    fn parse_backslash() {
        assert_eq!(parse_tag_path("methods\\sims\\hydro"), Some("methods/sims/hydro".to_string()));
    }

    #[test]
    fn parse_leading_trailing_slash() {
        assert_eq!(parse_tag_path("/methods/sims/"), Some("methods/sims".to_string()));
    }

    #[test]
    fn parse_empty() {
        assert_eq!(parse_tag_path(""), None);
        assert_eq!(parse_tag_path("   "), None);
        assert_eq!(parse_tag_path("///"), None);
    }

    #[test]
    fn leaf_extraction() {
        assert_eq!(tag_leaf("methods/sims/hydro"), "hydro");
        assert_eq!(tag_leaf("methods"), "methods");
    }

    #[test]
    fn parent_extraction() {
        assert_eq!(tag_parent("methods/sims/hydro"), Some("methods/sims".to_string()));
        assert_eq!(tag_parent("methods"), None);
    }

    #[test]
    fn depth_count() {
        assert_eq!(tag_depth("methods"), 0);
        assert_eq!(tag_depth("methods/sims"), 1);
        assert_eq!(tag_depth("methods/sims/hydro/AMR"), 3);
    }
}
