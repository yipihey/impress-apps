//! The UniFFI surface for a manuscript's papers — what it cites plus what was
//! collected to consider citing. The logic is
//! `impress_core::manuscript_reading_list`, which the
//! `imprint-project-service_project-*` verbs read too, so the GUI and an agent
//! see one list in one order.
//!
//! `manuscript_sync_reading_collection` is what imprint calls before opening
//! imbib's papers window: it folds the cited papers into the manuscript's imbib
//! collection so that ONE collection is the whole scope. The editor passes the
//! keys from its live buffer — a verb reading the stored text would lag what is
//! being typed.

use impress_core::manuscript_reading_list as rl;

use crate::{SharedStore, SharedStoreError};

/// One reading-list row.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedReadingListEntry {
    /// The imbib publication, or `None` for a cite key imbib does not hold.
    pub publication_id: Option<String>,
    pub cite_key: String,
    pub title: Option<String>,
    pub authors: Option<String>,
    pub year: Option<i64>,
    /// The manuscript cites it.
    pub cited: bool,
    /// It is in the manuscript's reading-list collection.
    pub collected: bool,
    /// imbib holds a PDF for it (fetch the bytes through imbib, not the path).
    pub has_pdf: bool,
    /// Last view or hand-add, ms since the epoch.
    pub last_activity_at: Option<i64>,
    /// Position of its first citation in the manuscript, if cited.
    pub citation_index: Option<u32>,
}

impl From<rl::ReadingListEntry> for SharedReadingListEntry {
    fn from(e: rl::ReadingListEntry) -> Self {
        Self {
            publication_id: e.publication_id,
            cite_key: e.cite_key,
            title: e.title,
            authors: e.authors,
            year: e.year,
            cited: e.cited,
            collected: e.collected,
            has_pdf: e.has_pdf,
            last_activity_at: e.last_activity_at,
            citation_index: e.citation_index,
        }
    }
}

/// What a collect did.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedCollectOutcome {
    pub collection_id: String,
    /// The reading-list collection did not exist and this call made it.
    pub created: bool,
    /// Publications that actually became members.
    pub added: Vec<String>,
}

/// What a reading-collection sync did.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedSyncCollectionOutcome {
    /// The collection imbib's papers window should open on.
    pub collection_id: String,
    pub collection_name: String,
    /// This call made the collection.
    pub created: bool,
    /// Cited papers this call added.
    pub added: Vec<String>,
    /// Cited keys imbib does not hold, in citation order — no paper exists to
    /// show, so imprint reports them instead.
    pub missing_cite_keys: Vec<String>,
    /// Members after the sync.
    pub member_count: u32,
}

#[cfg_attr(feature = "native", uniffi::export)]
impl SharedStore {
    /// The manuscript's reading list for the cite keys the caller scanned from
    /// its text (the editor passes its live buffer's keys).
    pub fn manuscript_reading_list(
        &self,
        manuscript_id: String,
        cite_keys: Vec<String>,
    ) -> Result<Vec<SharedReadingListEntry>, SharedStoreError> {
        Ok(rl::reading_list(&self.inner, &manuscript_id, &cite_keys)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// The manuscript's reading-list collection id, if it has one.
    pub fn manuscript_reading_collection(
        &self,
        manuscript_id: String,
    ) -> Result<Option<String>, SharedStoreError> {
        Ok(rl::reading_collection(&self.inner, &manuscript_id)?)
    }

    /// Make the manuscript's imbib collection hold every paper it cites,
    /// creating it on first use. Idempotent — imprint calls it every time it
    /// opens imbib's papers window.
    pub fn manuscript_sync_reading_collection(
        &self,
        manuscript_id: String,
        cite_keys: Vec<String>,
        collection_name: Option<String>,
    ) -> Result<SharedSyncCollectionOutcome, SharedStoreError> {
        let outcome = rl::sync_reading_collection(
            &self.inner,
            &manuscript_id,
            &cite_keys,
            collection_name.as_deref(),
        )?;
        Ok(SharedSyncCollectionOutcome {
            collection_id: outcome.collection_id,
            collection_name: outcome.collection_name,
            created: outcome.created,
            added: outcome.added,
            missing_cite_keys: outcome.missing_cite_keys,
            member_count: outcome.member_count,
        })
    }

    /// Add papers to the manuscript's reading list, making its collection on
    /// first use (filed under the library holding most of `cite_keys`, named
    /// `collection_name` or "<manuscript title> — papers").
    pub fn manuscript_collect(
        &self,
        manuscript_id: String,
        publication_ids: Vec<String>,
        collection_name: Option<String>,
        cite_keys: Vec<String>,
    ) -> Result<SharedCollectOutcome, SharedStoreError> {
        let outcome = rl::collect(
            &self.inner,
            &manuscript_id,
            &publication_ids,
            collection_name.as_deref(),
            &cite_keys,
        )?;
        Ok(SharedCollectOutcome {
            collection_id: outcome.collection_id,
            created: outcome.created,
            added: outcome.added,
        })
    }

    /// Remove papers from the reading list (the papers stay in imbib).
    pub fn manuscript_uncollect(
        &self,
        manuscript_id: String,
        publication_ids: Vec<String>,
    ) -> Result<Vec<String>, SharedStoreError> {
        Ok(rl::uncollect(
            &self.inner,
            &manuscript_id,
            &publication_ids,
        )?)
    }
}
