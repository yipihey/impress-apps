//! The pure decision: given the device, the tablet's folders and documents,
//! the papers in scope and their mirror rows, what happens this sync.
//!
//! No store, no network — every rule is a fixture test.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::PathBuf;

use impress_core::item::Value;
use impress_remarkable::rmdoc::SourceKind;
use impress_remarkable::RemarkableDocument;

use super::config::{EinkDeviceConfig, FolderStrategy, MirrorMode, MirrorState};
use super::folders::{self, FolderMap, FolderNeed};
use super::naming::{self, NameInputs};
use super::store::EinkMirrorRow;

/// The file that would be sent.
#[derive(Debug, Clone, PartialEq)]
pub struct LocalSource {
    pub linked_file_id: String,
    pub kind: SourceKind,
    pub filename: String,
    pub path: PathBuf,
    /// The store's hash when it recorded one; the executor hashes the bytes
    /// at upload time otherwise.
    pub sha256: Option<String>,
    pub size: i64,
}

/// One paper as the planner sees it.
#[derive(Debug, Clone)]
pub struct Candidate {
    pub publication_id: String,
    pub name: NameInputs,
    pub source: Option<LocalSource>,
    /// Every collection path the paper is filed under, sorted.
    pub collection_paths: Vec<Vec<String>>,
    pub library_name: Option<String>,
    pub library_is_inbox: bool,
    pub mirror: Option<EinkMirrorRow>,
}

pub struct PlanInputs<'a> {
    pub device: &'a EinkDeviceConfig,
    pub folders: &'a FolderMap,
    /// Documents under the root folder (any depth).
    pub remote_docs: &'a [RemarkableDocument],
    pub candidates: Vec<Candidate>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkipReason {
    /// Individual mode and not marked.
    NotMarked,
    /// Mirror-all mode, but the paper has no PDF/ePUB on this Mac.
    NoLocalSource,
    /// In an inbox library the device excludes.
    Inbox,
}

#[derive(Debug, Clone)]
pub enum PlanAction {
    /// Create a folder (rmdoc strategy); parents come first.
    EnsureFolder { path: Vec<String> },
    Upload {
        publication_id: String,
        mirror_id: Option<String>,
        source: LocalSource,
        target_path: Vec<String>,
        visible_name: String,
        upload_name: String,
        /// The copy this one replaces (a stale or removed one being re-sent).
        previous_remote_id: Option<String>,
    },
    /// Park the paper in a waiting state.
    Hold {
        publication_id: String,
        mirror_id: Option<String>,
        state: MirrorState,
        reason: String,
    },
    /// Row bookkeeping: a state change and/or field updates.
    Update {
        mirror_id: String,
        publication_id: String,
        state: Option<MirrorState>,
        fields: Vec<(String, Value)>,
        reason: String,
    },
    /// The tablet copy changed since it was last imported.
    Import {
        mirror_id: String,
        publication_id: String,
        remote_id: String,
        remote_name: String,
        remote_modified_ms: i64,
    },
    Skip {
        publication_id: String,
        reason: SkipReason,
    },
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct PlanSummary {
    pub to_upload: u32,
    pub awaiting_source: u32,
    pub awaiting_folder: u32,
    pub stale: u32,
    pub removed: u32,
    pub to_import: u32,
    pub unchanged: u32,
    pub skipped_no_source: u32,
    pub skipped_scope: u32,
    pub folders_to_create: u32,
}

#[derive(Debug, Clone, Default)]
pub struct SyncPlan {
    pub actions: Vec<PlanAction>,
    pub folder_needs: Vec<FolderNeed>,
    pub summary: PlanSummary,
}

fn path_display(folders: &FolderMap, parent: &str) -> String {
    if parent.is_empty() {
        String::new()
    } else {
        folders.path_of(parent).join("/")
    }
}

/// Decide the sync.
pub fn plan(inputs: PlanInputs<'_>) -> SyncPlan {
    let device = inputs.device;
    let known_remote: HashMap<&str, &RemarkableDocument> = inputs
        .remote_docs
        .iter()
        .map(|doc| (doc.id.as_str(), doc))
        .collect();
    let mapped_remote_ids: HashSet<String> = inputs
        .candidates
        .iter()
        .filter_map(|c| c.mirror.as_ref().and_then(|m| m.remote_id.clone()))
        .collect();

    let mut candidates = inputs.candidates;
    candidates.sort_by(|a, b| a.publication_id.cmp(&b.publication_id));
    let cite_keys: BTreeMap<String, String> = candidates
        .iter()
        .map(|c| (c.publication_id.clone(), c.name.cite_key.clone()))
        .collect();

    let mut plan = SyncPlan::default();
    let mut ensure_paths: BTreeSet<Vec<String>> = BTreeSet::new();
    let mut needs: Vec<FolderNeed> = Vec::new();
    // Uploads grouped by target path, for name collisions.
    let mut uploads: Vec<PlanAction> = Vec::new();

    for candidate in candidates {
        let publication_id = candidate.publication_id.clone();
        let mirror = candidate.mirror.as_ref();
        let state = mirror.map(EinkMirrorRow::mirror_state);
        let resend = mirror.map(|m| m.resend).unwrap_or(false);

        // --- rows that reached the tablet ------------------------------
        if let (Some(row), Some(remote_id)) = (mirror, mirror.and_then(|m| m.remote_id.clone())) {
            match known_remote.get(remote_id.as_str()) {
                None => {
                    let on_tablet = matches!(
                        state,
                        Some(
                            MirrorState::Uploaded
                                | MirrorState::Stale
                                | MirrorState::Unmarked
                                | MirrorState::Failed
                        )
                    );
                    if on_tablet && !resend {
                        plan.actions.push(PlanAction::Update {
                            mirror_id: row.id.clone(),
                            publication_id: publication_id.clone(),
                            state: Some(MirrorState::RemovedOnDevice),
                            fields: vec![],
                            reason: format!("document {remote_id} is no longer on the tablet"),
                        });
                        plan.summary.removed += 1;
                        continue;
                    }
                    if !resend {
                        plan.summary.unchanged += 1;
                        continue;
                    }
                    // fall through: re-send
                }
                Some(doc) => {
                    let mut fields: Vec<(String, Value)> = Vec::new();
                    let recorded_parent = row.remote_parent_id.clone().unwrap_or_default();
                    if doc.parent != recorded_parent {
                        fields.push(("remote_parent_id".into(), Value::String(doc.parent.clone())));
                        fields.push((
                            "remote_path".into(),
                            Value::String(path_display(inputs.folders, &doc.parent)),
                        ));
                    }
                    if doc.visible_name != row.remote_name.clone().unwrap_or_default() {
                        fields.push((
                            "remote_name".into(),
                            Value::String(doc.visible_name.clone()),
                        ));
                    }
                    if Some(doc.last_modified_ms) != row.remote_modified_ms {
                        fields.push((
                            "remote_modified_ms".into(),
                            Value::Int(doc.last_modified_ms),
                        ));
                    }
                    let mut new_state = None;
                    if state == Some(MirrorState::Uploaded) && !resend {
                        if let Some(source) = &candidate.source {
                            let changed = match (&source.sha256, &row.uploaded_sha256) {
                                (Some(now), Some(then)) => now != then,
                                _ => false,
                            };
                            if changed {
                                new_state = Some(MirrorState::Stale);
                                plan.summary.stale += 1;
                            }
                        }
                    }
                    let import_worthy =
                        matches!(state, Some(MirrorState::Uploaded | MirrorState::Stale));
                    let newer = match (row.imported_modified_ms, row.uploaded_at_ms) {
                        (Some(imported), _) => doc.last_modified_ms > imported,
                        (None, Some(uploaded)) => doc.last_modified_ms > uploaded + 60_000,
                        (None, None) => false,
                    };
                    if import_worthy && newer && device.import_annotated_pdf {
                        plan.actions.push(PlanAction::Import {
                            mirror_id: row.id.clone(),
                            publication_id: publication_id.clone(),
                            remote_id: remote_id.clone(),
                            remote_name: doc.visible_name.clone(),
                            remote_modified_ms: doc.last_modified_ms,
                        });
                        plan.summary.to_import += 1;
                    }
                    if !fields.is_empty() || new_state.is_some() {
                        plan.actions.push(PlanAction::Update {
                            mirror_id: row.id.clone(),
                            publication_id: publication_id.clone(),
                            state: new_state,
                            fields,
                            reason: "tablet listing changed".into(),
                        });
                    }
                    // Bookkeeping is not a change to the paper's fate.
                    if new_state.is_none() && !resend {
                        plan.summary.unchanged += 1;
                    }
                    if !resend {
                        continue;
                    }
                }
            }
        }

        // --- scope --------------------------------------------------------
        let marked = mirror.map(|m| m.marked).unwrap_or(false);
        let in_scope = match device.mirror_mode {
            MirrorMode::All => {
                if candidate.library_is_inbox && !device.include_inbox {
                    plan.actions.push(PlanAction::Skip {
                        publication_id: publication_id.clone(),
                        reason: SkipReason::Inbox,
                    });
                    plan.summary.skipped_scope += 1;
                    false
                } else {
                    true
                }
            }
            MirrorMode::Individual => {
                if !marked {
                    plan.actions.push(PlanAction::Skip {
                        publication_id: publication_id.clone(),
                        reason: SkipReason::NotMarked,
                    });
                    plan.summary.skipped_scope += 1;
                }
                marked
            }
        };
        if !in_scope {
            continue;
        }

        // --- source -------------------------------------------------------
        let Some(source) = candidate.source.clone() else {
            // A paper the user marked keeps waiting for its file in either
            // mode; an unmarked paper that mirror-all merely swept up is
            // skipped without a row.
            if marked || device.mirror_mode == MirrorMode::Individual {
                if state != Some(MirrorState::AwaitingSource) {
                    plan.actions.push(PlanAction::Hold {
                        publication_id: publication_id.clone(),
                        mirror_id: mirror.map(|m| m.id.clone()),
                        state: MirrorState::AwaitingSource,
                        reason: "no PDF or ePUB on this Mac yet".into(),
                    });
                }
                plan.summary.awaiting_source += 1;
            } else {
                plan.actions.push(PlanAction::Skip {
                    publication_id: publication_id.clone(),
                    reason: SkipReason::NoLocalSource,
                });
                plan.summary.skipped_no_source += 1;
            }
            continue;
        };

        // --- target folder ------------------------------------------------
        let chain: Vec<String> = if device.mirror_collections {
            candidate
                .collection_paths
                .first()
                .cloned()
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        let target = folders::target_path(
            &device.root_folder_name,
            candidate.library_name.as_deref(),
            device.include_library_level,
            &chain,
        );
        match inputs.folders.resolve(&target) {
            Ok(_) => {}
            Err(missing) => match device.folder_strategy {
                FolderStrategy::Rmdoc => {
                    for depth in missing.present_depth..target.len() {
                        ensure_paths.insert(target[..=depth].to_vec());
                    }
                }
                FolderStrategy::Checklist => {
                    needs.extend(folders::needs_for(&target, &missing, 1));
                    if state != Some(MirrorState::AwaitingFolder) {
                        plan.actions.push(PlanAction::Hold {
                            publication_id: publication_id.clone(),
                            mirror_id: mirror.map(|m| m.id.clone()),
                            state: MirrorState::AwaitingFolder,
                            reason: format!(
                                "folder {} does not exist on the tablet",
                                target.join("/")
                            ),
                        });
                    }
                    plan.summary.awaiting_folder += 1;
                    continue;
                }
            },
        }

        let visible_name = naming::visible_name(&candidate.name);
        let previous_remote_id = if resend {
            mirror.and_then(|m| m.remote_id.clone())
        } else {
            None
        };
        uploads.push(PlanAction::Upload {
            publication_id: publication_id.clone(),
            mirror_id: mirror.map(|m| m.id.clone()),
            upload_name: naming::upload_filename(&visible_name, source.kind),
            visible_name,
            source,
            target_path: target,
            previous_remote_id,
        });
    }

    // --- names: no two uploads (or an upload and an untracked tablet
    // document) may share a name inside one folder --------------------------
    let mut taken: HashMap<Vec<String>, HashSet<String>> = HashMap::new();
    for doc in inputs.remote_docs {
        if mapped_remote_ids.contains(&doc.id) {
            continue;
        }
        let path = inputs.folders.path_of(&doc.parent);
        taken
            .entry(path)
            .or_default()
            .insert(doc.visible_name.clone());
    }
    for action in uploads.iter_mut() {
        if let PlanAction::Upload {
            publication_id,
            visible_name,
            upload_name,
            source,
            target_path,
            ..
        } = action
        {
            let names = taken.entry(target_path.clone()).or_default();
            if names.contains(visible_name) {
                let cite_key = cite_keys
                    .get(publication_id)
                    .filter(|k| !k.is_empty())
                    .cloned()
                    .unwrap_or_else(|| publication_id.chars().take(8).collect());
                *visible_name = naming::with_collision_suffix(visible_name, &cite_key);
                *upload_name = naming::upload_filename(visible_name, source.kind);
            }
            names.insert(visible_name.clone());
        }
    }

    plan.summary.to_upload = uploads.len() as u32;
    plan.summary.folders_to_create = ensure_paths.len() as u32;
    let mut actions: Vec<PlanAction> = ensure_paths
        .into_iter()
        .map(|path| PlanAction::EnsureFolder { path })
        .collect();
    // Bookkeeping first (it never touches the tablet), then folders, then
    // uploads, then imports — the order the executor wants.
    let (imports, rest): (Vec<PlanAction>, Vec<PlanAction>) = plan
        .actions
        .into_iter()
        .partition(|a| matches!(a, PlanAction::Import { .. }));
    let mut ordered = rest;
    ordered.append(&mut actions);
    ordered.extend(uploads);
    ordered.extend(imports);
    plan.actions = ordered;
    plan.folder_needs = folders::checklist(needs);
    plan
}
