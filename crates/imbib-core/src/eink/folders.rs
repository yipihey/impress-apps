//! The tablet's folder tree, and the paths papers are filed under.
//!
//! The USB web interface reports folders as `CollectionType` entries with a
//! `Parent` id; a path like `imbib/Astro/Cosmology` is resolved by walking
//! names from the top level. Folders that do not exist become a checklist
//! (or, with the rmdoc strategy, folders the engine creates itself).

use std::collections::HashMap;

use impress_remarkable::{DocumentKind, RemarkableDocument};

use super::naming::folder_name;

/// Where a path stopped resolving.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MissingFolder {
    /// The deepest folder that does exist (`None` = the top level).
    pub present_id: Option<String>,
    /// How many leading path components exist.
    pub present_depth: usize,
}

/// The folders the tablet listed, indexed for path lookups.
#[derive(Debug, Clone, Default)]
pub struct FolderMap {
    /// (parent id or "" for the top level, exact name) → folder id.
    by_parent_name: HashMap<(String, String), String>,
    /// (parent, lowercased name) → folder id, for a lenient second look.
    by_parent_name_ci: HashMap<(String, String), String>,
    names: HashMap<String, String>,
    parents: HashMap<String, String>,
}

impl FolderMap {
    pub fn from_entries(entries: &[RemarkableDocument]) -> Self {
        let mut map = Self::default();
        for entry in entries.iter().filter(|e| e.kind == DocumentKind::Folder) {
            map.insert(&entry.id, &entry.parent, &entry.visible_name);
        }
        map
    }

    /// Record a folder (after the tablet listed it, or after we made one).
    pub fn insert(&mut self, id: &str, parent: &str, name: &str) {
        let name = name.trim().to_string();
        self.by_parent_name
            .insert((parent.to_string(), name.clone()), id.to_string());
        self.by_parent_name_ci
            .insert((parent.to_string(), name.to_lowercase()), id.to_string());
        self.names.insert(id.to_string(), name);
        self.parents.insert(id.to_string(), parent.to_string());
    }

    pub fn child(&self, parent: &str, name: &str) -> Option<&str> {
        let name = name.trim();
        self.by_parent_name
            .get(&(parent.to_string(), name.to_string()))
            .or_else(|| {
                self.by_parent_name_ci
                    .get(&(parent.to_string(), name.to_lowercase()))
            })
            .map(String::as_str)
    }

    pub fn name_of(&self, id: &str) -> Option<&str> {
        self.names.get(id).map(String::as_str)
    }

    pub fn parent_of(&self, id: &str) -> Option<&str> {
        self.parents.get(id).map(String::as_str)
    }

    /// The path of names from the top level down to a folder.
    pub fn path_of(&self, id: &str) -> Vec<String> {
        let mut path = Vec::new();
        let mut current = Some(id.to_string());
        let mut guard = 0;
        while let Some(folder) = current {
            if folder.is_empty() || guard > 64 {
                break;
            }
            match self.names.get(&folder) {
                Some(name) => path.push(name.clone()),
                None => break,
            }
            current = self.parents.get(&folder).cloned();
            guard += 1;
        }
        path.reverse();
        path
    }

    /// Resolve a path of names to the id of its last folder.
    pub fn resolve(&self, path: &[String]) -> Result<String, MissingFolder> {
        let mut parent = String::new();
        for (depth, name) in path.iter().enumerate() {
            match self.child(&parent, name) {
                Some(id) => parent = id.to_string(),
                None => {
                    return Err(MissingFolder {
                        present_id: (!parent.is_empty()).then_some(parent),
                        present_depth: depth,
                    })
                }
            }
        }
        if parent.is_empty() {
            Err(MissingFolder {
                present_id: None,
                present_depth: 0,
            })
        } else {
            Ok(parent)
        }
    }

    pub fn len(&self) -> usize {
        self.names.len()
    }

    pub fn is_empty(&self) -> bool {
        self.names.is_empty()
    }
}

/// A folder the tablet lacks and how many papers wait on it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct FolderNeed {
    /// Full path from the top level, e.g. `["imbib", "Library", "Cosmology"]`.
    pub path: Vec<String>,
    /// The deepest existing ancestor, or None for the top level.
    pub parent_id: Option<String>,
    pub publications: u32,
}

impl FolderNeed {
    pub fn display(&self) -> String {
        self.path.join("/")
    }
}

/// Merge duplicate needs and order them parents first, so a user can work
/// down the list (and the rmdoc strategy can create them in order).
pub fn checklist(needs: Vec<FolderNeed>) -> Vec<FolderNeed> {
    let mut merged: HashMap<Vec<String>, FolderNeed> = HashMap::new();
    for need in needs {
        merged
            .entry(need.path.clone())
            .and_modify(|existing| existing.publications += need.publications)
            .or_insert(need);
    }
    let mut out: Vec<FolderNeed> = merged.into_values().collect();
    out.sort_by(|a, b| {
        a.path
            .len()
            .cmp(&b.path.len())
            .then_with(|| a.path.cmp(&b.path))
    });
    out
}

/// Every missing prefix of a path, deepest existing ancestor known, so a
/// path three levels below the deepest folder yields three needs.
pub fn needs_for(path: &[String], missing: &MissingFolder, publications: u32) -> Vec<FolderNeed> {
    (missing.present_depth..path.len())
        .map(|depth| FolderNeed {
            path: path[..=depth].to_vec(),
            parent_id: if depth == missing.present_depth {
                missing.present_id.clone()
            } else {
                None
            },
            publications,
        })
        .collect()
}

/// The tablet path a paper is filed under.
pub fn target_path(
    root: &str,
    library: Option<&str>,
    include_library_level: bool,
    collection_chain: &[String],
) -> Vec<String> {
    let mut path = vec![folder_name(root)];
    if include_library_level {
        if let Some(library) = library {
            path.push(folder_name(library));
        }
    }
    path.extend(collection_chain.iter().map(|name| folder_name(name)));
    path
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(id: &str, parent: &str, name: &str) -> RemarkableDocument {
        RemarkableDocument {
            id: id.into(),
            visible_name: name.into(),
            kind: DocumentKind::Folder,
            parent: parent.into(),
            last_modified_ms: 0,
            pinned: false,
            file_type: String::new(),
            page_count: 0,
            has_annotations: false,
        }
    }

    #[test]
    fn paths_resolve_through_names_and_report_where_they_stop() {
        let map = FolderMap::from_entries(&[
            folder("r", "", "imbib"),
            folder("l", "r", "Library"),
            folder("c", "l", "Cosmology"),
        ]);
        assert_eq!(
            map.resolve(&["imbib".into(), "Library".into(), "Cosmology".into()]),
            Ok("c".into())
        );
        assert_eq!(
            map.resolve(&["imbib".into(), "library".into()]),
            Ok("l".into()),
            "case-insensitive fallback"
        );
        assert_eq!(
            map.resolve(&[
                "imbib".into(),
                "Library".into(),
                "Stars".into(),
                "Massive".into()
            ]),
            Err(MissingFolder {
                present_id: Some("l".into()),
                present_depth: 2
            })
        );
        assert_eq!(
            map.resolve(&["papers".into()]),
            Err(MissingFolder {
                present_id: None,
                present_depth: 0
            })
        );
        assert_eq!(map.path_of("c"), vec!["imbib", "Library", "Cosmology"]);
    }

    #[test]
    fn the_checklist_lists_every_missing_level_parents_first() {
        let path: Vec<String> = ["imbib", "Library", "Stars", "Massive"]
            .map(String::from)
            .to_vec();
        let missing = MissingFolder {
            present_id: Some("l".into()),
            present_depth: 2,
        };
        let mut needs = needs_for(&path, &missing, 2);
        needs.extend(needs_for(&path, &missing, 1));
        needs.extend(needs_for(
            &["imbib".into(), "Library".into(), "Cosmology".into()],
            &missing,
            1,
        ));
        let list = checklist(needs);
        let paths: Vec<String> = list.iter().map(FolderNeed::display).collect();
        assert_eq!(
            paths,
            vec![
                "imbib/Library/Cosmology",
                "imbib/Library/Stars",
                "imbib/Library/Stars/Massive"
            ]
        );
        assert_eq!(list[1].publications, 3, "duplicates merge their counts");
        assert_eq!(list[1].parent_id.as_deref(), Some("l"));
        assert_eq!(list[2].parent_id, None, "its parent does not exist yet");
    }

    #[test]
    fn target_paths_follow_the_device_options() {
        let chain = vec!["Cosmology".into(), "Reionization".into()];
        assert_eq!(
            target_path("imbib", Some("Library"), true, &chain),
            vec!["imbib", "Library", "Cosmology", "Reionization"]
        );
        assert_eq!(
            target_path("imbib", Some("Library"), false, &chain),
            vec!["imbib", "Cosmology", "Reionization"]
        );
        assert_eq!(
            target_path("imbib", Some("Library"), true, &[]),
            vec!["imbib", "Library"]
        );
        assert_eq!(target_path("imbib", None, true, &[]), vec!["imbib"]);
    }
}
