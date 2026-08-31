use std::collections::BTreeMap;
use std::io::Cursor;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use chrono::{DateTime, Utc};
use image::ImageReader;
use impress_ai::{AiStore, BlobDescriptor, BlobStore, FileBlobStore};
use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
use impress_core::query::{ItemQuery, Predicate, SortDescriptor};
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::schemas::CONTENT_BLOB_SCHEMA;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use reqwest::redirect::Policy;
use url::{Host, Url};
use uuid::Uuid;
use vw_service::{
    ChatGptFile, PhotoEvidence, PhotoEvidenceResult, PhotoEvidenceSearchResult, VwMcpImageBlock,
};

use crate::schemas::{VW_DIAGNOSTIC_SESSION_SCHEMA, VW_PHOTO_EVIDENCE_SCHEMA};

const MEDIA_SCHEMA: &str = "impress/artifact/media";
const MAX_PHOTO_BYTES: usize = 12 * 1024 * 1024;
const MAX_PHOTO_PIXELS: u64 = 50_000_000;
const MAX_SEARCH_RESULTS: u32 = 50;
const PHOTO_SOURCE_NAMESPACE: Uuid = Uuid::from_u128(0xd2d83c4b_760f_4c76_a0f6_967cfaf6a3d9);
const PHOTO_EVIDENCE_NAMESPACE: Uuid = Uuid::from_u128(0x7dc2e83b_4e39_4d87_b8ce_0f628a269167);

#[derive(Clone)]
pub struct PhotoEvidenceStore {
    blob_root: PathBuf,
    client: reqwest::Client,
}

impl PhotoEvidenceStore {
    pub fn new(blob_root: PathBuf) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .redirect(Policy::none())
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(45))
            .user_agent("impress-vw-photo-ingest/1.0")
            .build()
            .map_err(|error| format!("configure photo downloader: {error}"))?;
        Ok(Self { blob_root, client })
    }

    pub async fn ingest(
        &self,
        store: Arc<SqliteItemStore>,
        mut photo: ChatGptFile,
        input: PhotoDescription,
    ) -> PhotoEvidenceResult {
        photo.file_id = match validated_file_id(photo.file_id) {
            Ok(file_id) => file_id,
            Err(error) => return failure("invalid_input", error),
        };
        let evidence_id = evidence_id(&photo.file_id);
        match load_evidence(&store, evidence_id) {
            Ok(Some(existing)) => {
                return self.result_with_image(&store, existing, "already_stored")
            }
            Ok(None) => {}
            Err(error) => return failure("store_error", error),
        }
        let input = match input.validate(&store) {
            Ok(input) => input,
            Err(error) => return failure("invalid_input", error),
        };
        let url = match validated_download_url(&photo.download_url) {
            Ok(url) => url,
            Err(error) => return failure("invalid_file_url", error),
        };
        let bytes = match self.download(url).await {
            Ok(bytes) => bytes,
            Err(error) => return failure("download_failed", error),
        };
        self.ingest_bytes(store, photo, input, bytes)
    }

    pub fn ingest_bytes(
        &self,
        store: Arc<SqliteItemStore>,
        mut photo: ChatGptFile,
        input: PhotoDescription,
        bytes: Vec<u8>,
    ) -> PhotoEvidenceResult {
        photo.file_id = match validated_file_id(photo.file_id) {
            Ok(file_id) => file_id,
            Err(error) => return failure("invalid_input", error),
        };
        let evidence_id = evidence_id(&photo.file_id);
        match load_evidence(&store, evidence_id) {
            Ok(Some(existing)) => {
                return self.result_with_image(&store, existing, "already_stored")
            }
            Ok(None) => {}
            Err(error) => return failure("store_error", error),
        }
        let input = match input.validate(&store) {
            Ok(input) => input,
            Err(error) => return failure("invalid_input", error),
        };
        let file_name = normalize_file_name(photo.file_name);
        let image = match inspect_photo(&bytes, photo.mime_type.as_deref()) {
            Ok(image) => image,
            Err(error) => return failure("invalid_photo", error),
        };
        let blobs = match FileBlobStore::open(&self.blob_root) {
            Ok(blobs) => blobs,
            Err(error) => return failure("blob_store_error", error.to_string()),
        };
        let descriptor = match blobs.put(&bytes) {
            Ok(descriptor) => descriptor,
            Err(error) => return failure("blob_store_error", error.to_string()),
        };
        let content_blob_id = match content_blob_for_hash(&store, &descriptor.sha256) {
            Ok(Some(id)) => id,
            Ok(None) => {
                let ai = AiStore::from_store(store.clone(), "vw-t2-expert");
                match ai.ingest_blob(&blobs, &bytes, image.mime_type.clone(), file_name.clone()) {
                    Ok(attachment) => attachment.item_id,
                    Err(error) => return failure("store_error", error.to_string()),
                }
            }
            Err(error) => return failure("store_error", error),
        };
        let source_item_id = source_id(&descriptor.sha256);
        if let Err(error) = ensure_media_source(
            &store,
            source_item_id,
            MediaSourceInput {
                blob_id: content_blob_id,
                descriptor: &descriptor,
                image: &image,
                file_name: file_name.as_deref(),
                title: &input.title,
                tags: &input.tags,
            },
        ) {
            return failure("store_error", error);
        }
        let now = Utc::now();
        let evidence = PhotoEvidence {
            id: evidence_id.to_string(),
            source_item_id: source_item_id.to_string(),
            content_blob_id: content_blob_id.to_string(),
            source_content_hash: descriptor.sha256,
            external_file_id: photo.file_id,
            file_name,
            mime_type: image.mime_type.clone(),
            byte_length: descriptor.byte_length,
            pixel_width: image.width,
            pixel_height: image.height,
            title: input.title,
            description: input.description,
            component: input.component,
            tags: input.tags,
            captured_at: input.captured_at,
            received_at: now.to_rfc3339(),
            diagnostic_session_id: input.diagnostic_session_id,
        };
        if let Err(error) = insert_evidence(&store, &evidence, now) {
            return failure("store_error", error);
        }
        PhotoEvidenceResult {
            ok: true,
            status: "stored".into(),
            message: format!(
                "Stored '{}' as private VW photo evidence with immutable hash {}.",
                evidence.title, evidence.source_content_hash
            ),
            evidence: Some(evidence),
            mcp_content: vec![image_block(bytes, &image.mime_type)],
        }
    }

    pub fn get(&self, store: &SqliteItemStore, evidence_id: &str) -> PhotoEvidenceResult {
        let id = match Uuid::parse_str(evidence_id) {
            Ok(id) => id,
            Err(error) => return failure("invalid_input", format!("invalid evidence_id: {error}")),
        };
        match load_evidence(store, id) {
            Ok(Some(evidence)) => self.result_with_image(store, evidence, "retrieved"),
            Ok(None) => failure("not_found", "photo evidence was not found"),
            Err(error) => failure("store_error", error),
        }
    }

    pub fn search(
        &self,
        store: &SqliteItemStore,
        query: &str,
        diagnostic_session_id: Option<&str>,
        limit: u32,
    ) -> PhotoEvidenceSearchResult {
        let requested = if limit == 0 {
            10
        } else {
            limit.min(MAX_SEARCH_RESULTS)
        } as usize;
        let query = query.trim().to_lowercase();
        let mut hits = match store.query(&ItemQuery {
            schema: Some(VW_PHOTO_EVIDENCE_SCHEMA.into()),
            predicates: vec![],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            include_tags: true,
            include_references: false,
            ..Default::default()
        }) {
            Ok(items) => items
                .into_iter()
                .filter_map(|item| decode_evidence(&item).ok())
                .filter(|evidence| {
                    diagnostic_session_id.is_none_or(|session| {
                        evidence.diagnostic_session_id.as_deref() == Some(session)
                    })
                })
                .filter(|evidence| query.is_empty() || evidence_matches(evidence, &query))
                .take(requested)
                .collect::<Vec<_>>(),
            Err(error) => {
                return PhotoEvidenceSearchResult {
                    ok: false,
                    message: format!("search photo evidence: {error}"),
                    hits: vec![],
                }
            }
        };
        hits.sort_by(|a, b| b.received_at.cmp(&a.received_at));
        PhotoEvidenceSearchResult {
            ok: true,
            message: format!("Found {} VW photo evidence item(s).", hits.len()),
            hits,
        }
    }

    fn result_with_image(
        &self,
        store: &SqliteItemStore,
        evidence: PhotoEvidence,
        status: &str,
    ) -> PhotoEvidenceResult {
        match read_evidence_bytes(store, &self.blob_root, &evidence) {
            Ok(bytes) => PhotoEvidenceResult {
                ok: true,
                status: status.into(),
                message: format!("Resolved stored VW photo '{}'.", evidence.title),
                mcp_content: vec![image_block(bytes, &evidence.mime_type)],
                evidence: Some(evidence),
            },
            Err(error) => failure("blob_unavailable", error),
        }
    }

    async fn download(&self, url: Url) -> Result<Vec<u8>, String> {
        let mut response = self
            .client
            .get(url)
            .send()
            .await
            .map_err(|error| format!("download authorized photo: {error}"))?;
        if !response.status().is_success() {
            return Err(format!(
                "authorized photo download returned HTTP {}",
                response.status()
            ));
        }
        if response
            .content_length()
            .is_some_and(|length| length > MAX_PHOTO_BYTES as u64)
        {
            return Err(format!("photo exceeds the {MAX_PHOTO_BYTES} byte limit"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| format!("read authorized photo: {error}"))?
        {
            if bytes.len().saturating_add(chunk.len()) > MAX_PHOTO_BYTES {
                return Err(format!("photo exceeds the {MAX_PHOTO_BYTES} byte limit"));
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok(bytes)
    }
}

#[derive(Debug, Clone)]
pub struct PhotoDescription {
    pub title: String,
    pub description: String,
    pub component: Option<String>,
    pub diagnostic_session_id: Option<String>,
    pub captured_at: Option<String>,
    pub tags: Vec<String>,
}

impl PhotoDescription {
    fn validate(mut self, store: &SqliteItemStore) -> Result<Self, String> {
        self.title = bounded_required("title", self.title, 200)?;
        self.description = bounded_required("description", self.description, 8_000)?;
        self.component = bounded_optional("component", self.component, 200)?;
        self.tags = normalize_tags(self.tags)?;
        if let Some(value) = self.captured_at.take() {
            let captured = DateTime::parse_from_rfc3339(value.trim())
                .map_err(|error| format!("captured_at must be RFC3339: {error}"))?;
            self.captured_at = Some(captured.to_rfc3339());
        }
        if let Some(value) = self.diagnostic_session_id.as_deref() {
            let id = Uuid::parse_str(value)
                .map_err(|error| format!("invalid diagnostic_session_id: {error}"))?;
            match store.get(id).map_err(|error| error.to_string())? {
                Some(item) if item.schema == VW_DIAGNOSTIC_SESSION_SCHEMA => {}
                Some(_) => {
                    return Err("diagnostic_session_id is not a VW diagnostic session".into())
                }
                None => return Err("diagnostic_session_id does not exist".into()),
            }
        }
        Ok(self)
    }
}

#[derive(Debug)]
struct InspectedPhoto {
    mime_type: String,
    width: Option<u32>,
    height: Option<u32>,
}

fn inspect_photo(bytes: &[u8], declared_mime: Option<&str>) -> Result<InspectedPhoto, String> {
    if bytes.is_empty() {
        return Err("photo is empty".into());
    }
    if bytes.len() > MAX_PHOTO_BYTES {
        return Err(format!("photo exceeds the {MAX_PHOTO_BYTES} byte limit"));
    }
    let mime_type =
        sniff_mime(bytes).ok_or("unsupported image bytes; use JPEG, PNG, WebP, HEIC, or HEIF")?;
    if let Some(declared) = declared_mime.map(normalize_mime) {
        if declared.starts_with("image/") && declared != mime_type {
            return Err(format!(
                "declared MIME type {declared} does not match {mime_type} bytes"
            ));
        }
    }
    let dimensions = if matches!(mime_type, "image/jpeg" | "image/png" | "image/webp") {
        let reader = ImageReader::new(Cursor::new(bytes))
            .with_guessed_format()
            .map_err(|error| format!("inspect image format: {error}"))?;
        let (width, height) = reader
            .into_dimensions()
            .map_err(|error| format!("inspect image dimensions: {error}"))?;
        if u64::from(width) * u64::from(height) > MAX_PHOTO_PIXELS {
            return Err(format!("photo exceeds the {MAX_PHOTO_PIXELS} pixel limit"));
        }
        (Some(width), Some(height))
    } else {
        (None, None)
    };
    Ok(InspectedPhoto {
        mime_type: mime_type.into(),
        width: dimensions.0,
        height: dimensions.1,
    })
}

fn sniff_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        return Some("image/jpeg");
    }
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some("image/png");
    }
    if bytes.len() >= 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
        return match &bytes[8..12] {
            b"heic" | b"heix" | b"hevc" | b"hevx" => Some("image/heic"),
            b"mif1" | b"msf1" => Some("image/heif"),
            _ => None,
        };
    }
    None
}

fn normalize_mime(value: &str) -> String {
    match value.trim().to_ascii_lowercase().as_str() {
        "image/jpg" => "image/jpeg".into(),
        value => value.into(),
    }
}

fn validated_download_url(value: &str) -> Result<Url, String> {
    let url = Url::parse(value.trim()).map_err(|error| format!("invalid download_url: {error}"))?;
    if url.scheme() != "https" {
        return Err("download_url must use HTTPS".into());
    }
    if !url.username().is_empty() || url.password().is_some() || url.fragment().is_some() {
        return Err("download_url cannot contain credentials or a fragment".into());
    }
    match url.host() {
        Some(Host::Ipv4(address))
            if address.is_private() || address.is_loopback() || address.is_link_local() =>
        {
            Err("download_url cannot target a private or local address".into())
        }
        Some(Host::Ipv6(address)) if is_private_ipv6(address) => {
            Err("download_url cannot target a private or local address".into())
        }
        Some(Host::Domain(domain))
            if domain.eq_ignore_ascii_case("localhost")
                || domain.ends_with(".localhost")
                || domain.ends_with(".local")
                || domain.ends_with(".internal") =>
        {
            Err("download_url cannot target a private or local host".into())
        }
        Some(_) => Ok(url),
        None => Err("download_url requires a host".into()),
    }
}

fn validated_file_id(value: String) -> Result<String, String> {
    let value = value.trim();
    if value.is_empty() {
        return Err("photo.file_id is required".into());
    }
    if value.len() > 512 || value.chars().any(char::is_control) {
        return Err("photo.file_id is malformed".into());
    }
    Ok(value.into())
}

fn is_private_ipv6(address: std::net::Ipv6Addr) -> bool {
    address.is_loopback()
        || address.is_unspecified()
        || (address.segments()[0] & 0xfe00) == 0xfc00
        || (address.segments()[0] & 0xffc0) == 0xfe80
        || matches!(IpAddr::V6(address).to_canonical(), IpAddr::V4(v4) if v4.is_private() || v4.is_loopback() || v4.is_link_local())
}

struct MediaSourceInput<'a> {
    blob_id: Uuid,
    descriptor: &'a BlobDescriptor,
    image: &'a InspectedPhoto,
    file_name: Option<&'a str>,
    title: &'a str,
    tags: &'a [String],
}

fn ensure_media_source(
    store: &SqliteItemStore,
    id: Uuid,
    input: MediaSourceInput<'_>,
) -> Result<(), String> {
    let MediaSourceInput {
        blob_id,
        descriptor,
        image,
        file_name,
        title,
        tags,
    } = input;
    if let Some(existing) = store.get(id).map_err(|error| error.to_string())? {
        if existing.schema == MEDIA_SCHEMA
            && payload_string(&existing, "file_hash").as_deref() == Some(&descriptor.sha256)
        {
            return Ok(());
        }
        return Err("photo source id already exists with different immutable content".into());
    }
    let mut payload = BTreeMap::from([
        ("title".into(), Value::String(title.into())),
        (
            "artifact_subtype".into(),
            Value::String("vw-bus-photo".into()),
        ),
        ("file_hash".into(), Value::String(descriptor.sha256.clone())),
        (
            "file_size".into(),
            Value::Int(descriptor.byte_length as i64),
        ),
        (
            "file_mime_type".into(),
            Value::String(image.mime_type.clone()),
        ),
        (
            "capture_context".into(),
            Value::String("User photo shared with ChatGPT VW T2 Expert".into()),
        ),
    ]);
    if let Some(file_name) = file_name {
        payload.insert("file_name".into(), Value::String(file_name.into()));
    }
    let now = Utc::now();
    store
        .insert(Item {
            id,
            schema: MEDIA_SCHEMA.into(),
            payload,
            created: now,
            modified: now,
            author: "user:chatgpt-vw-t2-expert".into(),
            author_kind: ActorKind::Human,
            logical_clock: 0,
            origin: Some("chatgpt-vw-t2-expert".into()),
            canonical_id: Some(format!("sha256:{}", descriptor.sha256)),
            tags: photo_tags(tags),
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::Normal,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: Some("1.1.0".into()),
            batch_id: None,
            references: vec![TypedReference {
                target: blob_id,
                edge_type: EdgeType::Attaches,
                metadata: None,
            }],
            parent: None,
        })
        .map_err(|error| format!("insert media artifact: {error}"))?;
    Ok(())
}

fn insert_evidence(
    store: &SqliteItemStore,
    evidence: &PhotoEvidence,
    now: DateTime<Utc>,
) -> Result<(), String> {
    let data = serde_json::to_value(evidence)
        .ok()
        .and_then(|value| serde_json::from_value::<Value>(value).ok())
        .ok_or("serialize photo evidence")?;
    let mut payload = BTreeMap::from([
        ("title".into(), Value::String(evidence.title.clone())),
        ("data".into(), data),
        (
            "source_item_id".into(),
            Value::String(evidence.source_item_id.clone()),
        ),
        (
            "content_blob_id".into(),
            Value::String(evidence.content_blob_id.clone()),
        ),
        (
            "source_content_hash".into(),
            Value::String(evidence.source_content_hash.clone()),
        ),
        (
            "external_file_id".into(),
            Value::String(evidence.external_file_id.clone()),
        ),
        (
            "description".into(),
            Value::String(evidence.description.clone()),
        ),
        (
            "body".into(),
            Value::String(format!(
                "{}\n{}\n{}\n{}",
                evidence.title,
                evidence.description,
                evidence.component.as_deref().unwrap_or_default(),
                evidence.tags.join(" ")
            )),
        ),
    ]);
    if let Some(component) = &evidence.component {
        payload.insert("component".into(), Value::String(component.clone()));
    }
    if let Some(session) = &evidence.diagnostic_session_id {
        payload.insert(
            "diagnostic_session_id".into(),
            Value::String(session.clone()),
        );
    }
    let source_id = Uuid::parse_str(&evidence.source_item_id).map_err(|error| error.to_string())?;
    let blob_id = Uuid::parse_str(&evidence.content_blob_id).map_err(|error| error.to_string())?;
    let mut references = vec![
        TypedReference {
            target: source_id,
            edge_type: EdgeType::DerivedFrom,
            metadata: None,
        },
        TypedReference {
            target: blob_id,
            edge_type: EdgeType::Attaches,
            metadata: None,
        },
    ];
    if let Some(session) = &evidence.diagnostic_session_id {
        references.push(TypedReference {
            target: Uuid::parse_str(session).map_err(|error| error.to_string())?,
            edge_type: EdgeType::RelatesTo,
            metadata: None,
        });
    }
    store
        .insert(Item {
            id: Uuid::parse_str(&evidence.id).map_err(|error| error.to_string())?,
            schema: VW_PHOTO_EVIDENCE_SCHEMA.into(),
            payload,
            created: now,
            modified: now,
            author: "user:chatgpt-vw-t2-expert".into(),
            author_kind: ActorKind::Human,
            logical_clock: 0,
            origin: Some("chatgpt-vw-t2-expert".into()),
            canonical_id: Some(format!("chatgpt-file:{}", evidence.external_file_id)),
            tags: photo_tags(&evidence.tags),
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::Normal,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: Some("1.0.0".into()),
            batch_id: None,
            references,
            parent: Some(source_id),
        })
        .map_err(|error| format!("insert photo evidence: {error}"))?;
    Ok(())
}

fn read_evidence_bytes(
    store: &SqliteItemStore,
    blob_root: &Path,
    evidence: &PhotoEvidence,
) -> Result<Vec<u8>, String> {
    let blob_id = Uuid::parse_str(&evidence.content_blob_id).map_err(|error| error.to_string())?;
    let blob = store
        .get(blob_id)
        .map_err(|error| error.to_string())?
        .ok_or("content blob metadata is missing")?;
    if blob.schema != CONTENT_BLOB_SCHEMA {
        return Err("photo attachment does not resolve to a content blob".into());
    }
    let descriptor = BlobDescriptor {
        sha256: required_payload_string(&blob, "sha256")?,
        byte_length: payload_int(&blob, "byte_length")?
            .try_into()
            .map_err(|_| "content blob length is invalid")?,
        storage_kind: required_payload_string(&blob, "storage_kind")?,
        locator: required_payload_string(&blob, "locator")?,
    };
    if descriptor.sha256 != evidence.source_content_hash {
        return Err("photo evidence hash does not match its content blob".into());
    }
    FileBlobStore::open(blob_root)
        .map_err(|error| error.to_string())?
        .read(&descriptor)
        .map_err(|error| error.to_string())
}

fn content_blob_for_hash(store: &SqliteItemStore, hash: &str) -> Result<Option<Uuid>, String> {
    store
        .query(&ItemQuery {
            schema: Some(CONTENT_BLOB_SCHEMA.into()),
            predicates: vec![Predicate::Eq(
                "payload.sha256".into(),
                Value::String(hash.into()),
            )],
            limit: Some(1),
            include_tags: false,
            include_references: false,
            ..Default::default()
        })
        .map(|items| items.first().map(|item| item.id))
        .map_err(|error| format!("find content blob: {error}"))
}

fn load_evidence(store: &SqliteItemStore, id: Uuid) -> Result<Option<PhotoEvidence>, String> {
    match store.get(id).map_err(|error| error.to_string())? {
        Some(item) if item.schema == VW_PHOTO_EVIDENCE_SCHEMA => decode_evidence(&item).map(Some),
        Some(_) => Err("evidence id belongs to a different record kind".into()),
        None => Ok(None),
    }
}

fn decode_evidence(item: &Item) -> Result<PhotoEvidence, String> {
    item.payload
        .get("data")
        .and_then(|value| serde_json::to_value(value).ok())
        .and_then(|value| serde_json::from_value(value).ok())
        .ok_or_else(|| "photo evidence data is malformed".into())
}

fn image_block(bytes: Vec<u8>, mime_type: &str) -> VwMcpImageBlock {
    VwMcpImageBlock {
        kind: "image".into(),
        data: base64::engine::general_purpose::STANDARD.encode(bytes),
        mime_type: mime_type.into(),
    }
}

fn evidence_id(file_id: &str) -> Uuid {
    Uuid::new_v5(&PHOTO_EVIDENCE_NAMESPACE, file_id.trim().as_bytes())
}

fn source_id(hash: &str) -> Uuid {
    Uuid::new_v5(&PHOTO_SOURCE_NAMESPACE, hash.as_bytes())
}

fn evidence_matches(evidence: &PhotoEvidence, query: &str) -> bool {
    [
        Some(evidence.title.as_str()),
        Some(evidence.description.as_str()),
        evidence.component.as_deref(),
        evidence.file_name.as_deref(),
    ]
    .into_iter()
    .flatten()
    .chain(evidence.tags.iter().map(String::as_str))
    .any(|value| value.to_lowercase().contains(query))
}

fn normalize_file_name(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let leaf = value
            .split(['/', '\\'])
            .next_back()
            .unwrap_or_default()
            .trim();
        (!leaf.is_empty()).then(|| leaf.chars().take(255).collect())
    })
}

fn normalize_tags(tags: Vec<String>) -> Result<Vec<String>, String> {
    if tags.len() > 20 {
        return Err("at most 20 tags may be supplied".into());
    }
    let mut normalized = tags
        .into_iter()
        .map(|tag| tag.trim().to_lowercase())
        .filter(|tag| !tag.is_empty())
        .collect::<Vec<_>>();
    if normalized.iter().any(|tag| tag.len() > 80) {
        return Err("photo tags must be at most 80 characters".into());
    }
    normalized.sort();
    normalized.dedup();
    Ok(normalized)
}

fn photo_tags(tags: &[String]) -> Vec<String> {
    let mut result = vec!["vw/photo-evidence".into()];
    result.extend(tags.iter().map(|tag| format!("vw/photo/{tag}")));
    result
}

fn bounded_required(name: &str, value: String, max: usize) -> Result<String, String> {
    let value = value.trim();
    if value.is_empty() {
        return Err(format!("{name} is required"));
    }
    if value.chars().count() > max {
        return Err(format!("{name} must be at most {max} characters"));
    }
    Ok(value.into())
}

fn bounded_optional(
    name: &str,
    value: Option<String>,
    max: usize,
) -> Result<Option<String>, String> {
    value
        .map(|value| bounded_required(name, value, max))
        .transpose()
}

fn payload_string(item: &Item, key: &str) -> Option<String> {
    match item.payload.get(key) {
        Some(Value::String(value)) => Some(value.clone()),
        _ => None,
    }
}

fn required_payload_string(item: &Item, key: &str) -> Result<String, String> {
    payload_string(item, key).ok_or_else(|| format!("content blob is missing {key}"))
}

fn payload_int(item: &Item, key: &str) -> Result<i64, String> {
    match item.payload.get(key) {
        Some(Value::Int(value)) => Ok(*value),
        _ => Err(format!("content blob is missing {key}")),
    }
}

fn failure(status: &str, message: impl Into<String>) -> PhotoEvidenceResult {
    PhotoEvidenceResult {
        ok: false,
        status: status.into(),
        message: message.into(),
        evidence: None,
        mcp_content: vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{DynamicImage, ImageFormat, RgbaImage};

    fn png() -> Vec<u8> {
        let mut bytes = Vec::new();
        DynamicImage::ImageRgba8(RgbaImage::from_pixel(3, 2, image::Rgba([1, 2, 3, 255])))
            .write_to(&mut Cursor::new(&mut bytes), ImageFormat::Png)
            .unwrap();
        bytes
    }

    fn description() -> PhotoDescription {
        PhotoDescription {
            title: "Thermo-time switch wiring".into(),
            description: "User photo of the connector and nearby harness.".into(),
            component: Some("thermo-time switch".into()),
            diagnostic_session_id: None,
            captured_at: Some("2026-08-08T10:00:00+02:00".into()),
            tags: vec!["engine bay".into(), "wiring".into()],
        }
    }

    fn file() -> ChatGptFile {
        ChatGptFile {
            download_url: "https://files.oaiusercontent.com/temporary".into(),
            file_id: "file_photo_fixture".into(),
            mime_type: Some("image/png".into()),
            file_name: Some("../engine.png".into()),
        }
    }

    #[test]
    fn stores_searches_and_retrieves_private_photo_evidence() {
        let temp = tempfile::tempdir().unwrap();
        let store = Arc::new(SqliteItemStore::open_in_memory().unwrap());
        let photos = PhotoEvidenceStore::new(temp.path().join("blobs")).unwrap();
        let result = photos.ingest_bytes(store.clone(), file(), description(), png());
        assert!(result.ok, "{}", result.message);
        assert_eq!(result.status, "stored");
        assert_eq!(result.evidence.as_ref().unwrap().pixel_width, Some(3));
        assert_eq!(result.evidence.as_ref().unwrap().pixel_height, Some(2));
        assert_eq!(
            result.evidence.as_ref().unwrap().file_name.as_deref(),
            Some("engine.png")
        );
        assert_eq!(result.mcp_content[0].mime_type, "image/png");

        let search = photos.search(&store, "connector", None, 10);
        assert!(search.ok);
        assert_eq!(search.hits.len(), 1);
        let retrieved = photos.get(&store, &search.hits[0].id);
        assert!(retrieved.ok);
        assert_eq!(retrieved.mcp_content[0].kind, "image");

        let artifact = store
            .get(Uuid::parse_str(&search.hits[0].source_item_id).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(artifact.schema, MEDIA_SCHEMA);
        assert_eq!(artifact.visibility, Visibility::Private);
        assert_eq!(artifact.author_kind, ActorKind::Human);
    }

    #[test]
    fn retrying_the_same_chatgpt_file_is_idempotent() {
        let temp = tempfile::tempdir().unwrap();
        let store = Arc::new(SqliteItemStore::open_in_memory().unwrap());
        let photos = PhotoEvidenceStore::new(temp.path().join("blobs")).unwrap();
        let first = photos.ingest_bytes(store.clone(), file(), description(), png());
        let second = photos.ingest_bytes(store.clone(), file(), description(), png());
        assert!(first.ok && second.ok);
        assert_eq!(second.status, "already_stored");
        assert_eq!(first.evidence.unwrap().id, second.evidence.unwrap().id);
        assert_eq!(
            store
                .query(&ItemQuery {
                    schema: Some(VW_PHOTO_EVIDENCE_SCHEMA.into()),
                    ..Default::default()
                })
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn rejects_non_images_and_unsafe_download_urls() {
        assert!(inspect_photo(b"not an image", Some("image/png")).is_err());
        assert!(validated_download_url("file:///etc/passwd").is_err());
        assert!(validated_download_url("http://files.example/photo.jpg").is_err());
        assert!(validated_download_url("https://127.0.0.1/photo.jpg").is_err());
        assert!(validated_download_url("https://files.oaiusercontent.com/photo.jpg").is_ok());
    }
}
