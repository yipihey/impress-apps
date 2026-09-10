//! Working copies (ADR-0030 D11): a project materialised into a directory
//! the author (or Veusz, lilook, git, an agent's shell) edits, then checked
//! back in. The rows stay the truth; the directory is a view of them that
//! can drift, and this module says exactly how.
//!
//! Pure: it compares two trees — the store's and the directory's (read by
//! `import::import_directory`) — by content hash. The service does the
//! writes (the entry through the document, the rest as rows).

use serde::{Deserialize, Serialize};

use super::model::ProjectTree;

/// What differs between the rows and a working copy.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkingCopyStatus {
    /// In both, with different bytes.
    pub changed: Vec<String>,
    /// In the directory only (not build residue, which the walk skips).
    pub added: Vec<String>,
    /// A row the directory no longer has.
    pub missing: Vec<String>,
    pub unchanged: Vec<String>,
}

impl WorkingCopyStatus {
    pub fn is_clean(&self) -> bool {
        self.changed.is_empty() && self.added.is_empty() && self.missing.is_empty()
    }

    /// Everything a check-in would write (changed + added), in path order.
    pub fn to_check_in(&self) -> Vec<String> {
        let mut v: Vec<String> = self.changed.iter().chain(&self.added).cloned().collect();
        v.sort();
        v
    }
}

/// Compare the store's tree with the directory's. The directory's entry is
/// matched by the store's entry PATH (a working copy keeps the entry where
/// the store says it is); its own `entry` guess is ignored.
pub fn diff(store: &ProjectTree, directory: &ProjectTree) -> WorkingCopyStatus {
    let mut status = WorkingCopyStatus::default();
    for file in store.all_files() {
        match directory.file(&file.path) {
            None => status.missing.push(file.path.clone()),
            Some(d) if d.content_hash == file.content_hash => {
                status.unchanged.push(file.path.clone())
            }
            Some(_) => status.changed.push(file.path.clone()),
        }
    }
    for file in directory.all_files() {
        if !store.contains(&file.path) {
            status.added.push(file.path.clone());
        }
    }
    status.changed.sort();
    status.added.sort();
    status.missing.sort();
    status.unchanged.sort();
    status
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::model::{FileRole, ProjectFile};

    #[test]
    fn a_working_copy_diff_names_every_kind_of_drift() {
        let store = ProjectTree::new(
            "m",
            "P",
            "typst",
            ProjectFile::text("main.typ", FileRole::Main, "= P"),
            vec![
                ProjectFile::text("chapters/a.typ", FileRole::Chapter, "a"),
                ProjectFile::text("chapters/gone.typ", FileRole::Chapter, "gone"),
            ],
            vec![],
        );
        let directory = ProjectTree::new(
            "dir",
            "",
            "typst",
            ProjectFile::text("main.typ", FileRole::Main, "= P edited"),
            vec![
                ProjectFile::text("chapters/a.typ", FileRole::Chapter, "a"),
                ProjectFile::text("chapters/new.typ", FileRole::Chapter, "new"),
            ],
            vec![],
        );
        let s = diff(&store, &directory);
        assert_eq!(s.changed, vec!["main.typ"]);
        assert_eq!(s.added, vec!["chapters/new.typ"]);
        assert_eq!(s.missing, vec!["chapters/gone.typ"]);
        assert_eq!(s.unchanged, vec!["chapters/a.typ"]);
        assert!(!s.is_clean());
        assert_eq!(s.to_check_in(), vec!["chapters/new.typ", "main.typ"]);
        assert!(diff(&store, &store).is_clean());
    }
}
