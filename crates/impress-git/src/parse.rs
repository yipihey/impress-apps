use chrono::{DateTime, Utc};

use crate::models::{
    Branch, DiffFile, DiffSummary, FileState, FileStatus, LogEntry, RemoteInfo, RepoStatus,
};

/// Errors from parsing git output.
#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("unexpected format: {0}")]
    UnexpectedFormat(String),
    #[error("invalid date: {0}")]
    InvalidDate(String),
}

/// Parse `git status --porcelain=v2 --branch` output into a `RepoStatus`.
///
/// Porcelain v2 format:
/// - `# branch.head <name>` — current branch
/// - `# branch.ab +<ahead> -<behind>` — ahead/behind counts
/// - `1 <XY> ...  <path>` — ordinary changed entry
/// - `2 <XY> ... <path>\t<origPath>` — renamed/copied entry
/// - `u <XY> ... <path>` — unmerged entry
/// - `? <path>` — untracked file
pub fn parse_status_porcelain_v2(output: &str) -> Result<RepoStatus, ParseError> {
    let mut branch = String::new();
    let mut ahead: u32 = 0;
    let mut behind: u32 = 0;
    let mut modified = Vec::new();
    let mut staged = Vec::new();
    let mut untracked = Vec::new();
    let mut has_conflicts = false;

    for line in output.lines() {
        if line.starts_with("# branch.head ") {
            branch = line.trim_start_matches("# branch.head ").to_string();
        } else if line.starts_with("# branch.ab ") {
            // Format: # branch.ab +N -M
            let ab = line.trim_start_matches("# branch.ab ");
            for token in ab.split_whitespace() {
                if let Some(n) = token.strip_prefix('+') {
                    ahead = n.parse().unwrap_or(0);
                } else if let Some(n) = token.strip_prefix('-') {
                    behind = n.parse().unwrap_or(0);
                }
            }
        } else if line.starts_with('?') {
            // Untracked: ? <path>
            let path = line[2..].to_string();
            untracked.push(path);
        } else if line.starts_with('u') {
            // Unmerged entry
            has_conflicts = true;
            let path = extract_path_from_entry(line);
            modified.push(FileStatus {
                path,
                status: FileState::Unmerged,
            });
        } else if line.starts_with('1') || line.starts_with('2') {
            // Ordinary (1) or renamed/copied (2) entry
            // Format: 1 XY <sub> <mH> <mI> <mW> <hH> <hI> <path>
            // Format: 2 XY <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\t<origPath>
            let parts: Vec<&str> = line.splitn(2, ' ').collect();
            if parts.len() < 2 {
                continue;
            }
            let rest = parts[1];
            if rest.len() < 2 {
                continue;
            }
            let xy = &rest[..2];
            let index_status = xy.as_bytes()[0];
            let worktree_status = xy.as_bytes()[1];
            let path = extract_path_from_entry(line);

            // Index changes → staged
            if index_status != b'.' {
                staged.push(FileStatus {
                    path: path.clone(),
                    status: char_to_file_state(index_status as char),
                });
            }
            // Worktree changes → modified
            if worktree_status != b'.' {
                modified.push(FileStatus {
                    path,
                    status: char_to_file_state(worktree_status as char),
                });
            }
        }
        // Skip other header lines (# branch.oid, etc.)
    }

    let is_clean = modified.is_empty() && staged.is_empty() && untracked.is_empty() && !has_conflicts;

    Ok(RepoStatus {
        branch,
        ahead,
        behind,
        modified,
        staged,
        untracked,
        has_conflicts,
        is_clean,
    })
}

/// Extract the file path from a porcelain v2 entry line.
fn extract_path_from_entry(line: &str) -> String {
    // For renamed entries (type 2), path is after the last tab, but we want the new path
    // which comes before the tab. For type 1/u, path is the last space-delimited field.
    if line.starts_with('2') {
        // 2 XY sub mH mI mW hH hI Xscore path\torigPath
        if let Some(tab_pos) = line.find('\t') {
            // Everything between last space before tab and tab is the new path
            let before_tab = &line[..tab_pos];
            if let Some(last_space) = before_tab.rfind(' ') {
                return before_tab[last_space + 1..].to_string();
            }
        }
    }
    // Type 1 or u: path is after the last space
    line.rsplit(' ').next().unwrap_or("").to_string()
}

fn char_to_file_state(c: char) -> FileState {
    match c {
        'M' => FileState::Modified,
        'A' => FileState::Added,
        'D' => FileState::Deleted,
        'R' => FileState::Renamed,
        'C' => FileState::Copied,
        'U' => FileState::Unmerged,
        _ => FileState::Modified, // fallback
    }
}

/// Parse `git log --format=%H%x00%h%x00%s%x00%an%x00%ae%x00%aI` output.
///
/// Each line is a NUL-delimited record: hash, short_hash, subject, author, email, iso_date
pub fn parse_log(output: &str) -> Result<Vec<LogEntry>, ParseError> {
    let mut entries = Vec::new();
    for line in output.lines() {
        if line.is_empty() {
            continue;
        }
        let fields: Vec<&str> = line.split('\0').collect();
        if fields.len() < 6 {
            return Err(ParseError::UnexpectedFormat(format!(
                "expected 6 NUL-delimited fields, got {}: {:?}",
                fields.len(),
                line
            )));
        }
        let date = DateTime::parse_from_rfc3339(fields[5])
            .map(|d| d.with_timezone(&Utc))
            .map_err(|e| ParseError::InvalidDate(format!("{}: {}", fields[5], e)))?;

        entries.push(LogEntry {
            hash: fields[0].to_string(),
            short_hash: fields[1].to_string(),
            message: fields[2].to_string(),
            author: fields[3].to_string(),
            email: fields[4].to_string(),
            date,
        });
    }
    Ok(entries)
}

/// Parse `git branch -a --format=%(HEAD)%x00%(refname:short)%x00%(upstream:short)%x00%(refname:rstrip=-2)`.
pub fn parse_branch_list(output: &str) -> Result<Vec<Branch>, ParseError> {
    let mut branches = Vec::new();
    for line in output.lines() {
        if line.is_empty() {
            continue;
        }
        let fields: Vec<&str> = line.split('\0').collect();
        if fields.len() < 4 {
            return Err(ParseError::UnexpectedFormat(format!(
                "expected 4 NUL-delimited fields in branch line: {:?}",
                line
            )));
        }
        let is_current = fields[0].trim() == "*";
        let name = fields[1].to_string();
        let upstream = if fields[2].is_empty() {
            None
        } else {
            Some(fields[2].to_string())
        };
        let refname_base = fields[3].to_string();
        let is_remote = refname_base.contains("remotes");

        branches.push(Branch {
            name,
            is_remote,
            is_current,
            upstream,
        });
    }
    Ok(branches)
}

/// Parse `git diff --numstat` output into a `DiffSummary`.
///
/// Each line: `<additions>\t<deletions>\t<path>`
/// Binary files show `-\t-\t<path>`.
pub fn parse_diff_stat(output: &str) -> Result<DiffSummary, ParseError> {
    let mut files = Vec::new();
    let mut total_insertions: u32 = 0;
    let mut total_deletions: u32 = 0;

    for line in output.lines() {
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() < 3 {
            continue;
        }
        let additions = parts[0].parse::<u32>().unwrap_or(0);
        let removals = parts[1].parse::<u32>().unwrap_or(0);
        let path = parts[2..].join("\t"); // Handle paths with tabs (rare but possible)
        let status = if parts[0] == "-" && parts[1] == "-" {
            "binary".to_string()
        } else {
            "text".to_string()
        };

        total_insertions += additions;
        total_deletions += removals;

        files.push(DiffFile {
            path,
            status,
            additions,
            removals,
        });
    }

    Ok(DiffSummary {
        files,
        insertions: total_insertions,
        deletions: total_deletions,
    })
}

/// Parse `git remote -v` output into a list of `RemoteInfo`.
///
/// Each line: `<name>\t<url> (fetch|push)`
/// Two lines per remote (fetch + push).
pub fn parse_remote_list(output: &str) -> Result<Vec<RemoteInfo>, ParseError> {
    use std::collections::HashMap;

    // Collect fetch/push URLs per remote name
    let mut fetch_urls: HashMap<String, String> = HashMap::new();
    let mut push_urls: HashMap<String, String> = HashMap::new();

    for line in output.lines() {
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() < 2 {
            continue;
        }
        let name = parts[0].to_string();
        let rest = parts[1];
        if let Some(url) = rest.strip_suffix(" (fetch)") {
            fetch_urls.insert(name, url.to_string());
        } else if let Some(url) = rest.strip_suffix(" (push)") {
            push_urls.insert(name, url.to_string());
        }
    }

    // Merge into RemoteInfo structs
    let mut remotes: Vec<RemoteInfo> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();

    for name in fetch_urls.keys().chain(push_urls.keys()) {
        if seen.contains(name) {
            continue;
        }
        seen.insert(name.clone());
        remotes.push(RemoteInfo {
            name: name.clone(),
            fetch_url: fetch_urls.get(name).cloned().unwrap_or_default(),
            push_url: push_urls.get(name).cloned().unwrap_or_default(),
        });
    }

    remotes.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(remotes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_status_clean() {
        let output = "# branch.oid abc123\n# branch.head main\n# branch.ab +0 -0\n";
        let status = parse_status_porcelain_v2(output).unwrap();
        assert_eq!(status.branch, "main");
        assert_eq!(status.ahead, 0);
        assert_eq!(status.behind, 0);
        assert!(status.is_clean);
        assert!(status.modified.is_empty());
        assert!(status.staged.is_empty());
        assert!(status.untracked.is_empty());
    }

    #[test]
    fn parse_status_with_changes() {
        let output = "\
# branch.oid abc123
# branch.head feature/latex
# branch.ab +3 -1
1 .M N... 100644 100644 100644 abc def main.tex
1 A. N... 000000 100644 000000 000 abc new_file.tex
? notes.txt
";
        let status = parse_status_porcelain_v2(output).unwrap();
        assert_eq!(status.branch, "feature/latex");
        assert_eq!(status.ahead, 3);
        assert_eq!(status.behind, 1);
        assert!(!status.is_clean);

        assert_eq!(status.modified.len(), 1);
        assert_eq!(status.modified[0].path, "main.tex");
        assert_eq!(status.modified[0].status, FileState::Modified);

        assert_eq!(status.staged.len(), 1);
        assert_eq!(status.staged[0].path, "new_file.tex");
        assert_eq!(status.staged[0].status, FileState::Added);

        assert_eq!(status.untracked, vec!["notes.txt"]);
    }

    #[test]
    fn parse_status_with_conflict() {
        let output = "\
# branch.head main
# branch.ab +0 -0
u UU N... 100644 100644 100644 100644 abc def ghi main.tex
";
        let status = parse_status_porcelain_v2(output).unwrap();
        assert!(status.has_conflicts);
        assert_eq!(status.modified.len(), 1);
        assert_eq!(status.modified[0].status, FileState::Unmerged);
    }

    #[test]
    fn parse_log_entries() {
        let output = "\
abc123def456abc123def456abc123def456abc123\0abc123d\0Add introduction section\0Alice\0alice@example.com\02025-01-15T10:30:00+00:00
def789abc123def789abc123def789abc123def789\0def789a\0Fix bibliography\0Bob\0bob@example.com\02025-01-14T08:00:00+00:00
";
        let entries = parse_log(output).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].short_hash, "abc123d");
        assert_eq!(entries[0].message, "Add introduction section");
        assert_eq!(entries[0].author, "Alice");
        assert_eq!(entries[1].author, "Bob");
    }

    #[test]
    fn parse_branch_list_basic() {
        let output = "\
*\0main\0origin/main\0refs/heads
 \0feature/latex\0\0refs/heads
 \0origin/main\0\0refs/remotes
";
        let branches = parse_branch_list(output).unwrap();
        assert_eq!(branches.len(), 3);

        assert!(branches[0].is_current);
        assert_eq!(branches[0].name, "main");
        assert_eq!(branches[0].upstream, Some("origin/main".into()));
        assert!(!branches[0].is_remote);

        assert!(!branches[1].is_current);
        assert_eq!(branches[1].name, "feature/latex");
        assert!(branches[1].upstream.is_none());

        assert!(branches[2].is_remote);
    }

    #[test]
    fn parse_diff_stat_basic() {
        let output = "\
10\t3\tmain.tex
5\t0\tintro.tex
-\t-\tfigures/plot.png
";
        let summary = parse_diff_stat(output).unwrap();
        assert_eq!(summary.files.len(), 3);
        assert_eq!(summary.insertions, 15);
        assert_eq!(summary.deletions, 3);
        assert_eq!(summary.files[0].path, "main.tex");
        assert_eq!(summary.files[0].additions, 10);
        assert_eq!(summary.files[0].removals, 3);
        assert_eq!(summary.files[2].status, "binary");
    }

    #[test]
    fn parse_remote_list_basic() {
        let output = "\
origin\tgit@github.com:user/repo.git (fetch)
origin\tgit@github.com:user/repo.git (push)
upstream\thttps://github.com/upstream/repo.git (fetch)
upstream\thttps://github.com/upstream/repo.git (push)
";
        let remotes = parse_remote_list(output).unwrap();
        assert_eq!(remotes.len(), 2);
        assert_eq!(remotes[0].name, "origin");
        assert_eq!(remotes[0].fetch_url, "git@github.com:user/repo.git");
        assert_eq!(remotes[1].name, "upstream");
        assert_eq!(
            remotes[1].push_url,
            "https://github.com/upstream/repo.git"
        );
    }

    #[test]
    fn parse_status_empty_output() {
        let status = parse_status_porcelain_v2("").unwrap();
        assert!(status.branch.is_empty());
        assert!(status.is_clean);
    }

    #[test]
    fn parse_log_empty() {
        let entries = parse_log("").unwrap();
        assert!(entries.is_empty());
    }

    #[test]
    fn parse_diff_stat_empty() {
        let summary = parse_diff_stat("").unwrap();
        assert!(summary.files.is_empty());
        assert_eq!(summary.insertions, 0);
    }
}
