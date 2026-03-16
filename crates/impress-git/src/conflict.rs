use crate::models::{ConflictRegion, FileState, RepoStatus, ResolvedRegion};

/// Return paths of files with unmerged status from a `RepoStatus`.
pub fn detect_conflicts(status: &RepoStatus) -> Vec<String> {
    status
        .modified
        .iter()
        .filter(|f| f.status == FileState::Unmerged)
        .map(|f| f.path.clone())
        .collect()
}

/// Parse conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`) from file content.
///
/// Supports both two-way (`<<<<<<<`/`=======`/`>>>>>>>`) and three-way
/// (`<<<<<<<`/`|||||||`/`=======`/`>>>>>>>`) conflict markers.
pub fn parse_conflict_regions(content: &str) -> Vec<ConflictRegion> {
    let mut regions = Vec::new();
    let mut i = 0;
    let bytes = content.as_bytes();

    while i < bytes.len() {
        // Look for <<<<<<< marker at start of line
        if is_marker_at(content, i, "<<<<<<<") {
            let start_offset = i;
            let mut ours = String::new();
            let mut base: Option<String> = None;
            let mut theirs = String::new();

            // Advance past the <<<<<<< line
            i = next_line(content, i);

            // Parse "ours" section — until ||||||| or =======
            let mut current_section = &mut ours;
            loop {
                if i >= bytes.len() {
                    break;
                }
                if is_marker_at(content, i, "|||||||") {
                    // Three-way: switch to base section
                    base = Some(String::new());
                    i = next_line(content, i);
                    current_section = base.as_mut().unwrap();
                    continue;
                }
                if is_marker_at(content, i, "=======") {
                    // Switch to theirs section
                    i = next_line(content, i);
                    current_section = &mut theirs;
                    continue;
                }
                if is_marker_at(content, i, ">>>>>>>") {
                    let end_offset = next_line(content, i);
                    regions.push(ConflictRegion {
                        ours: ours.clone(),
                        theirs: theirs.clone(),
                        base: base.clone(),
                        start_offset,
                        end_offset,
                    });
                    i = end_offset;
                    break;
                }
                // Accumulate line into current section
                let line_end = next_line(content, i);
                current_section.push_str(&content[i..line_end]);
                i = line_end;
            }
        } else {
            i = next_line(content, i);
        }
    }

    regions
}

/// Apply resolved regions back onto the original conflicted content.
///
/// Regions must be sorted by `start_offset` ascending. Each region's byte
/// range is replaced with its resolution text.
pub fn apply_resolution(content: &str, regions: &[ResolvedRegion]) -> String {
    let mut result = String::with_capacity(content.len());
    let mut pos = 0;

    for region in regions {
        // Copy content before this region
        if region.start_offset > pos {
            result.push_str(&content[pos..region.start_offset]);
        }
        // Insert the resolution
        result.push_str(&region.resolution);
        pos = region.end_offset;
    }

    // Copy remaining content after last region
    if pos < content.len() {
        result.push_str(&content[pos..]);
    }

    result
}

/// Check if a conflict marker starts at the given byte offset.
fn is_marker_at(content: &str, offset: usize, marker: &str) -> bool {
    content[offset..].starts_with(marker)
}

/// Advance to the start of the next line after `offset`.
fn next_line(content: &str, offset: usize) -> usize {
    match content[offset..].find('\n') {
        Some(pos) => offset + pos + 1,
        None => content.len(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{FileState, FileStatus};

    #[test]
    fn detect_conflicts_from_status() {
        let status = RepoStatus {
            branch: "main".into(),
            ahead: 0,
            behind: 0,
            modified: vec![
                FileStatus { path: "clean.tex".into(), status: FileState::Modified },
                FileStatus { path: "conflict.tex".into(), status: FileState::Unmerged },
                FileStatus { path: "another.tex".into(), status: FileState::Unmerged },
            ],
            staged: vec![],
            untracked: vec![],
            has_conflicts: true,
            is_clean: false,
        };
        let conflicts = detect_conflicts(&status);
        assert_eq!(conflicts, vec!["conflict.tex", "another.tex"]);
    }

    #[test]
    fn parse_two_way_conflict() {
        let content = "\
Some preamble text.
<<<<<<< HEAD
Our version of the line.
=======
Their version of the line.
>>>>>>> feature-branch
Some trailing text.
";
        let regions = parse_conflict_regions(content);
        assert_eq!(regions.len(), 1);
        assert_eq!(regions[0].ours, "Our version of the line.\n");
        assert_eq!(regions[0].theirs, "Their version of the line.\n");
        assert!(regions[0].base.is_none());
    }

    #[test]
    fn parse_three_way_conflict() {
        let content = "\
<<<<<<< HEAD
Our change.
||||||| merged common ancestors
Original text.
=======
Their change.
>>>>>>> branch
";
        let regions = parse_conflict_regions(content);
        assert_eq!(regions.len(), 1);
        assert_eq!(regions[0].ours, "Our change.\n");
        assert_eq!(regions[0].base, Some("Original text.\n".into()));
        assert_eq!(regions[0].theirs, "Their change.\n");
    }

    #[test]
    fn parse_multiple_conflicts() {
        let content = "\
Line 1
<<<<<<< HEAD
AAA
=======
BBB
>>>>>>> branch
Line 2
<<<<<<< HEAD
CCC
=======
DDD
>>>>>>> branch
Line 3
";
        let regions = parse_conflict_regions(content);
        assert_eq!(regions.len(), 2);
        assert_eq!(regions[0].ours, "AAA\n");
        assert_eq!(regions[0].theirs, "BBB\n");
        assert_eq!(regions[1].ours, "CCC\n");
        assert_eq!(regions[1].theirs, "DDD\n");
    }

    #[test]
    fn apply_resolution_replaces_regions() {
        let content = "\
Line 1
<<<<<<< HEAD
AAA
=======
BBB
>>>>>>> branch
Line 2
";
        let regions = parse_conflict_regions(content);
        let resolved: Vec<ResolvedRegion> = regions
            .iter()
            .map(|r| ResolvedRegion {
                start_offset: r.start_offset,
                end_offset: r.end_offset,
                resolution: "Merged result.\n".into(),
            })
            .collect();

        let result = apply_resolution(content, &resolved);
        assert!(result.contains("Line 1\n"));
        assert!(result.contains("Merged result.\n"));
        assert!(result.contains("Line 2\n"));
        assert!(!result.contains("<<<<<<<"));
        assert!(!result.contains(">>>>>>>"));
    }

    #[test]
    fn no_conflicts_in_clean_file() {
        let content = "Just a normal file.\nNo conflicts here.\n";
        let regions = parse_conflict_regions(content);
        assert!(regions.is_empty());
    }
}
