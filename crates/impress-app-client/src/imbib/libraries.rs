//! All 43 `ImbibLibraryService` method clients.

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::error::{AppClientError, Result};
use crate::imbib::ImbibClient;
use crate::transport::{decode_envelope, decode_text};

use imbib_service::library_service::{
    CollectionRecord, DismissedPaperRecord, ImportSummary, LibraryRecord, LinkedFileRecord,
    MutationResult, MutedItemRecord, PaperImport, PublicationDetailRecord, PublicationSummary,
};

// ---------------------------------------------------------------------------
// Generic envelope shapes (one per shape, reused across endpoints)
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct OkStatus {
    status: String,
}

fn check_ok(s: &OkStatus) -> Result<()> {
    if s.status == "ok" {
        Ok(())
    } else {
        Err(AppClientError::Api(s.status.clone()))
    }
}

// ---------------------------------------------------------------------------
// Library lifecycle
// ---------------------------------------------------------------------------

impl ImbibClient {
    pub async fn list_libraries(&self) -> Result<Vec<LibraryRecord>> {
        #[derive(Deserialize)]
        struct R {
            status: String,
            libraries: Vec<LibraryRecord>,
        }
        let url = self.base_url.join("/api/libraries")?;
        let resp = self.http.get(url).send().await?;
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.libraries)
    }

    pub async fn create_library(&self, name: String) -> Result<LibraryRecord> {
        #[derive(Deserialize)]
        struct R {
            status: String,
            library: LibraryRecord,
        }
        let url = self.base_url.join("/api/libraries")?;
        let resp = self
            .http
            .post(url)
            .json(&json!({"name": name}))
            .send()
            .await?;
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.library)
    }

    pub async fn delete_library_undoable(&self, id: String) -> Result<MutationResult> {
        let url = self.base_url.join(&format!("/api/libraries/{}", id))?;
        let resp = self.http.delete(url).send().await?;
        let body: OkStatus = decode_envelope(resp).await?;
        check_ok(&body)?;
        Ok(MutationResult {
            affected_count: 1,
            ok: true,
        })
    }

    pub async fn get_default_library(&self) -> Result<Option<LibraryRecord>> {
        #[derive(Deserialize)]
        struct R {
            status: String,
            library: Option<LibraryRecord>,
        }
        let url = self.base_url.join("/api/libraries/default")?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.library)
    }

    pub async fn set_library_default(&self, id: String) -> Result<MutationResult> {
        let url = self
            .base_url
            .join(&format!("/api/libraries/{}/set-default", id))?;
        let resp = self.http.post(url).send().await?;
        let body: OkStatus = decode_envelope(resp).await?;
        check_ok(&body)?;
        Ok(MutationResult {
            affected_count: 1,
            ok: true,
        })
    }

    pub async fn get_inbox_library(&self) -> Result<Option<LibraryRecord>> {
        #[derive(Deserialize)]
        struct R {
            status: String,
            library: Option<LibraryRecord>,
        }
        let url = self.base_url.join("/api/libraries/inbox")?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.library)
    }
}

// ---------------------------------------------------------------------------
// Collection lifecycle
// ---------------------------------------------------------------------------

impl ImbibClient {
    pub async fn list_collections(&self, library_id: String) -> Result<Vec<CollectionRecord>> {
        #[derive(Deserialize)]
        struct R {
            status: String,
            collections: Vec<CollectionRecord>,
        }
        let mut url = self.base_url.join("/api/collections")?;
        url.query_pairs_mut().append_pair("library_id", &library_id);
        let resp = self.http.get(url).send().await?;
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.collections)
    }

    pub async fn create_collection(
        &self,
        name: String,
        library_id: String,
        is_smart: bool,
        query: Option<String>,
    ) -> Result<CollectionRecord> {
        #[derive(Deserialize)]
        struct R {
            status: String,
            collection: CollectionRecord,
        }
        let url = self.base_url.join("/api/collections")?;
        let body = json!({
            "name": name,
            "library_id": library_id,
            "is_smart": is_smart,
            "query": query,
        });
        let resp = self.http.post(url).json(&body).send().await?;
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.collection)
    }

    pub async fn add_to_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> Result<MutationResult> {
        let n = publication_ids.len() as u32;
        let url = self
            .base_url
            .join(&format!("/api/collections/{}/papers", collection_id))?;
        let body = json!({"action": "add", "identifiers": publication_ids});
        let resp = self.http.put(url).json(&body).send().await?;
        let s: OkStatus = decode_envelope(resp).await?;
        check_ok(&s)?;
        Ok(MutationResult {
            affected_count: n,
            ok: true,
        })
    }

    pub async fn remove_from_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> Result<MutationResult> {
        let n = publication_ids.len() as u32;
        let url = self
            .base_url
            .join(&format!("/api/collections/{}/papers", collection_id))?;
        let body = json!({"action": "remove", "identifiers": publication_ids});
        let resp = self.http.put(url).json(&body).send().await?;
        let s: OkStatus = decode_envelope(resp).await?;
        check_ok(&s)?;
        Ok(MutationResult {
            affected_count: n,
            ok: true,
        })
    }

    pub async fn list_collection_members(
        &self,
        collection_id: String,
        sort_field: String,
        ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<PublicationSummary>> {
        #[derive(Deserialize)]
        struct R {
            status: String,
            papers: Vec<PublicationSummary>,
        }
        let mut url = self
            .base_url
            .join(&format!("/api/collections/{}/papers", collection_id))?;
        let lim = if limit == 0 { 50 } else { limit };
        url.query_pairs_mut()
            .append_pair("limit", &lim.to_string())
            .append_pair("offset", &offset.to_string())
            .append_pair("sort", &sort_field)
            .append_pair("ascending", &ascending.to_string());
        let resp = self.http.get(url).send().await?;
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.papers)
    }

    pub async fn purge_dismissed_from_collection(
        &self,
        collection_id: String,
    ) -> Result<MutationResult> {
        let url = self.base_url.join(&format!(
            "/api/collections/{}/purge-dismissed",
            collection_id
        ))?;
        let resp = self.http.post(url).send().await?;
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            count: u32,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(MutationResult {
            affected_count: body.count,
            ok: true,
        })
    }
}

// ---------------------------------------------------------------------------
// Paper queries
// ---------------------------------------------------------------------------

impl ImbibClient {
    pub async fn list_publications(
        &self,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<PublicationSummary>> {
        self.search_with_params(
            None, None, None, None, None, None, limit, offset, None, None,
        )
        .await
    }

    pub async fn query_publications(
        &self,
        library_id: String,
        _sort_field: String,
        _ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<PublicationSummary>> {
        self.search_with_params(
            None,
            None,
            None,
            None,
            None,
            Some(library_id),
            limit,
            offset,
            None,
            None,
        )
        .await
    }

    pub async fn query_unread(
        &self,
        parent_id: Option<String>,
        _sort_field: String,
        _ascending: bool,
        limit: u32,
    ) -> Result<Vec<PublicationSummary>> {
        // imbib's /api/search supports `read=false`.
        self.search_with_params(
            None,
            None,
            None,
            Some(false),
            None,
            parent_id,
            limit,
            0,
            None,
            None,
        )
        .await
    }

    pub async fn query_starred(
        &self,
        parent_id: Option<String>,
        _sort_field: String,
        _ascending: bool,
        limit: u32,
    ) -> Result<Vec<PublicationSummary>> {
        // Routed through a dedicated count/list endpoint to be added in Phase D;
        // for now use the general search with a tag filter trick (no starred query param).
        // Fall back: empty results until Phase D adds GET /api/papers/starred.
        let mut url = self.base_url.join("/api/papers/starred")?;
        let lim = if limit == 0 { 50 } else { limit };
        url.query_pairs_mut().append_pair("limit", &lim.to_string());
        if let Some(pid) = parent_id {
            url.query_pairs_mut().append_pair("parent_id", &pid);
        }
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            papers: Vec<PublicationSummary>,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.papers)
    }

    pub async fn query_recent(
        &self,
        limit: u32,
        parent_id: Option<String>,
    ) -> Result<Vec<PublicationSummary>> {
        let mut url = self.base_url.join("/api/papers/recent")?;
        let lim = if limit == 0 { 50 } else { limit };
        url.query_pairs_mut().append_pair("limit", &lim.to_string());
        if let Some(pid) = parent_id {
            url.query_pairs_mut().append_pair("parent_id", &pid);
        }
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            papers: Vec<PublicationSummary>,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.papers)
    }

    pub async fn search_publications(
        &self,
        query: String,
        limit: u32,
    ) -> Result<Vec<PublicationSummary>> {
        self.search_with_params(
            Some(query),
            None,
            None,
            None,
            None,
            None,
            limit,
            0,
            None,
            None,
        )
        .await
    }

    pub async fn get_publication(&self, id: String) -> Result<Option<PublicationSummary>> {
        // imbib uses cite-key in /api/papers/{citeKey}.
        let cite_key = self.resolve_cite_key(&id).await?;
        let url = self
            .base_url
            .join(&format!("/api/papers/{}", urlencoding::encode(&cite_key)))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            paper: PublicationSummary,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(Some(body.paper))
    }

    pub async fn get_publication_detail(
        &self,
        id: String,
    ) -> Result<Option<PublicationDetailRecord>> {
        let cite_key = self.resolve_cite_key(&id).await?;
        let url = self.base_url.join(&format!(
            "/api/papers/{}?detail=1",
            urlencoding::encode(&cite_key)
        ))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            paper: PublicationDetailRecord,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(Some(body.paper))
    }

    pub async fn count_publications(&self) -> Result<u32> {
        // imbib's `/api/search?limit=1` with empty q returns `count: 0` (not
        // total). Real total = sum of paperCount across libraries.
        let libs = self.list_libraries().await?;
        Ok(libs.iter().map(|l| l.publication_count.max(0) as u32).sum())
    }

    pub async fn count_unread(&self, parent_id: Option<String>) -> Result<u32> {
        let mut url = self.base_url.join("/api/papers/count/unread")?;
        if let Some(pid) = parent_id {
            url.query_pairs_mut().append_pair("parent_id", &pid);
        }
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(0);
        }
        self.decode_count(resp).await
    }

    pub async fn count_starred(&self, parent_id: Option<String>) -> Result<u32> {
        let mut url = self.base_url.join("/api/papers/count/starred")?;
        if let Some(pid) = parent_id {
            url.query_pairs_mut().append_pair("parent_id", &pid);
        }
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(0);
        }
        self.decode_count(resp).await
    }

    pub async fn count_flagged(&self, color: Option<String>) -> Result<u32> {
        let mut url = self.base_url.join("/api/papers/count/flagged")?;
        if let Some(c) = color {
            url.query_pairs_mut().append_pair("color", &c);
        }
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(0);
        }
        self.decode_count(resp).await
    }

    async fn decode_count(&self, resp: reqwest::Response) -> Result<u32> {
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            count: u32,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.count)
    }

    /// Shared helper for the `/api/search` family.
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn search_with_params(
        &self,
        q: Option<String>,
        tag: Option<String>,
        flag: Option<String>,
        read: Option<bool>,
        collection: Option<String>,
        library: Option<String>,
        limit: u32,
        offset: u32,
        added_after: Option<String>,
        added_before: Option<String>,
    ) -> Result<Vec<PublicationSummary>> {
        let mut url = self.base_url.join("/api/search")?;
        let lim = if limit == 0 { 50 } else { limit };
        {
            let mut qs = url.query_pairs_mut();
            qs.append_pair("limit", &lim.to_string());
            qs.append_pair("offset", &offset.to_string());
            if let Some(v) = q {
                qs.append_pair("q", &v);
            }
            if let Some(v) = tag {
                qs.append_pair("tag", &v);
            }
            if let Some(v) = flag {
                qs.append_pair("flag", &v);
            }
            if let Some(v) = read {
                qs.append_pair("read", if v { "true" } else { "false" });
            }
            if let Some(v) = collection {
                qs.append_pair("collection", &v);
            }
            if let Some(v) = library {
                qs.append_pair("library", &v);
            }
            if let Some(v) = added_after {
                qs.append_pair("addedAfter", &v);
            }
            if let Some(v) = added_before {
                qs.append_pair("addedBefore", &v);
            }
        }
        let resp = self.http.get(url).send().await?;
        #[derive(Deserialize)]
        struct R {
            status: String,
            papers: Vec<PublicationSummary>,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.papers)
    }
}

// ---------------------------------------------------------------------------
// Paper mutations
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct IdsBody {
    identifiers: Vec<String>,
}

impl ImbibClient {
    pub async fn set_read(&self, ids: Vec<String>, read: bool) -> Result<MutationResult> {
        let n = ids.len() as u32;
        let url = self.base_url.join("/api/papers/read")?;
        let body = json!({"identifiers": ids, "read": read});
        let resp = self.http.put(url).json(&body).send().await?;
        let s: OkStatus = decode_envelope(resp).await?;
        check_ok(&s)?;
        Ok(MutationResult {
            affected_count: n,
            ok: true,
        })
    }

    pub async fn set_starred(&self, ids: Vec<String>, starred: bool) -> Result<MutationResult> {
        let n = ids.len() as u32;
        let url = self.base_url.join("/api/papers/star")?;
        let body = json!({"identifiers": ids, "starred": starred});
        let resp = self.http.put(url).json(&body).send().await?;
        let s: OkStatus = decode_envelope(resp).await?;
        check_ok(&s)?;
        Ok(MutationResult {
            affected_count: n,
            ok: true,
        })
    }

    pub async fn set_flag(
        &self,
        ids: Vec<String>,
        color: Option<String>,
    ) -> Result<MutationResult> {
        let n = ids.len() as u32;
        let url = self.base_url.join("/api/papers/flag")?;
        let body = json!({"identifiers": ids, "flag": {"color": color}});
        let resp = self.http.put(url).json(&body).send().await?;
        let s: OkStatus = decode_envelope(resp).await?;
        check_ok(&s)?;
        Ok(MutationResult {
            affected_count: n,
            ok: true,
        })
    }

    pub async fn delete_publications_undoable(&self, ids: Vec<String>) -> Result<MutationResult> {
        let n = ids.len() as u32;
        let url = self.base_url.join("/api/papers")?;
        let resp = self
            .http
            .delete(url)
            .json(&IdsBody { identifiers: ids })
            .send()
            .await?;
        let s: OkStatus = decode_envelope(resp).await?;
        check_ok(&s)?;
        Ok(MutationResult {
            affected_count: n,
            ok: true,
        })
    }

    pub async fn move_publications(
        &self,
        publication_ids: Vec<String>,
        to_library_id: String,
    ) -> Result<MutationResult> {
        let n = publication_ids.len() as u32;
        let url = self.base_url.join("/api/papers/move")?;
        let body = json!({"publication_ids": publication_ids, "to_library_id": to_library_id});
        let resp = self.http.post(url).json(&body).send().await?;
        let s: OkStatus = decode_envelope(resp).await?;
        check_ok(&s)?;
        Ok(MutationResult {
            affected_count: n,
            ok: true,
        })
    }

    pub async fn duplicate_publications(
        &self,
        ids: Vec<String>,
        to_library_id: String,
    ) -> Result<Vec<String>> {
        let url = self.base_url.join("/api/papers/duplicate")?;
        let body = json!({"ids": ids, "to_library_id": to_library_id});
        let resp = self.http.post(url).json(&body).send().await?;
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            ids: Vec<String>,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.ids)
    }

    pub async fn deduplicate_library(&self, library_id: String) -> Result<u32> {
        let url = self
            .base_url
            .join(&format!("/api/libraries/{}/deduplicate", library_id))?;
        let resp = self.http.post(url).send().await?;
        self.decode_count(resp).await
    }
}

// ---------------------------------------------------------------------------
// Dismissed/muted
// ---------------------------------------------------------------------------

impl ImbibClient {
    pub async fn dismiss_paper(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        cite_key: Option<String>,
    ) -> Result<Option<DismissedPaperRecord>> {
        let url = self.base_url.join("/api/dismissed-papers")?;
        let body =
            json!({"doi": doi, "arxiv_id": arxiv_id, "bibcode": bibcode, "cite_key": cite_key});
        let resp = self.http.post(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            dismissed: Option<DismissedPaperRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.dismissed)
    }

    pub async fn is_paper_dismissed(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        cite_key: Option<String>,
    ) -> Result<bool> {
        let mut url = self.base_url.join("/api/dismissed-papers/check")?;
        {
            let mut qs = url.query_pairs_mut();
            if let Some(v) = doi {
                qs.append_pair("doi", &v);
            }
            if let Some(v) = arxiv_id {
                qs.append_pair("arxiv_id", &v);
            }
            if let Some(v) = bibcode {
                qs.append_pair("bibcode", &v);
            }
            if let Some(v) = cite_key {
                qs.append_pair("cite_key", &v);
            }
        }
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(false);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            dismissed: bool,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.dismissed)
    }

    pub async fn list_dismissed_papers(
        &self,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<DismissedPaperRecord>> {
        let mut url = self.base_url.join("/api/dismissed-papers")?;
        let lim = if limit == 0 { 100 } else { limit };
        url.query_pairs_mut()
            .append_pair("limit", &lim.to_string())
            .append_pair("offset", &offset.to_string());
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            papers: Vec<DismissedPaperRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.papers)
    }

    pub async fn list_muted_items(&self) -> Result<Vec<MutedItemRecord>> {
        let url = self.base_url.join("/api/muted-items")?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            items: Vec<MutedItemRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.items)
    }

    pub async fn create_muted_item(
        &self,
        mute_type: String,
        value: String,
    ) -> Result<Option<MutedItemRecord>> {
        let url = self.base_url.join("/api/muted-items")?;
        let body = json!({"mute_type": mute_type, "value": value});
        let resp = self.http.post(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            item: Option<MutedItemRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.item)
    }
}

// ---------------------------------------------------------------------------
// BibTeX import/export
// ---------------------------------------------------------------------------

impl ImbibClient {
    pub async fn import_papers(
        &self,
        papers: Vec<PaperImport>,
        library_id: String,
    ) -> Result<ImportSummary> {
        // imbib's POST /api/papers/add accepts identifiers but not direct BibTeX.
        // Use the new POST /api/papers/import-batch route (Phase D) that takes
        // {papers: [...], library_id: ...} matching our PaperImport DTO.
        let url = self.base_url.join("/api/papers/import-batch")?;
        let body = json!({"papers": papers, "library_id": library_id});
        let resp = self.http.post(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(AppClientError::NotFound(
                "POST /api/papers/import-batch (Phase D)".into(),
            ));
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(flatten)]
            summary: ImportSummary,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.summary)
    }

    pub async fn import_bibtex(&self, bibtex: String, library_id: String) -> Result<Vec<String>> {
        let url = self.base_url.join("/api/papers/import-bibtex")?;
        let body = json!({"bibtex": bibtex, "library_id": library_id});
        let resp = self.http.post(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            ids: Vec<String>,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.ids)
    }

    pub async fn export_bibtex(&self, ids: Vec<String>) -> Result<String> {
        // imbib accepts comma-separated keys in ?keys=
        let keys = ids.join(",");
        let mut url = self.base_url.join("/api/export")?;
        url.query_pairs_mut()
            .append_pair("keys", &keys)
            .append_pair("format", "bibtex");
        let resp = self.http.get(url).send().await?;
        decode_text(resp).await
    }

    pub async fn export_all_bibtex(&self, library_id: String) -> Result<String> {
        let url = self
            .base_url
            .join(&format!("/api/libraries/{}/export-bibtex", library_id))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(String::new());
        }
        decode_text(resp).await
    }
}

// ---------------------------------------------------------------------------
// Linked files / PDFs
// ---------------------------------------------------------------------------

impl ImbibClient {
    pub async fn list_linked_files(&self, publication_id: String) -> Result<Vec<LinkedFileRecord>> {
        let cite_key = self.resolve_cite_key(&publication_id).await?;
        let url = self.base_url.join(&format!(
            "/api/papers/{}/files",
            urlencoding::encode(&cite_key)
        ))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            files: Vec<LinkedFileRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.files)
    }

    pub async fn count_pdfs(&self, publication_id: String) -> Result<u32> {
        let cite_key = self.resolve_cite_key(&publication_id).await?;
        let url = self.base_url.join(&format!(
            "/api/papers/{}/files/count",
            urlencoding::encode(&cite_key)
        ))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(0);
        }
        self.decode_count(resp).await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn add_linked_file(
        &self,
        publication_id: String,
        filename: String,
        relative_path: Option<String>,
        file_type: Option<String>,
        file_size: i64,
        sha256: Option<String>,
        is_pdf: bool,
    ) -> Result<Option<LinkedFileRecord>> {
        let cite_key = self.resolve_cite_key(&publication_id).await?;
        let url = self.base_url.join(&format!(
            "/api/papers/{}/files",
            urlencoding::encode(&cite_key)
        ))?;
        let body = json!({
            "filename": filename,
            "relative_path": relative_path,
            "file_type": file_type,
            "file_size": file_size,
            "sha256": sha256,
            "is_pdf": is_pdf,
        });
        let resp = self.http.post(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            file: Option<LinkedFileRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check_ok(&OkStatus {
            status: body.status,
        })?;
        Ok(body.file)
    }
}
