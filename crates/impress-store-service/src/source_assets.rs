//! Content-addressed PDF assets and bounded deterministic page rendering.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;

use image::GenericImageView;
use sha2::{Digest, Sha256};

use crate::store::store_path;

pub const DEFAULT_PAGE_DPI: u32 = 150;
pub const DEFAULT_FIGURE_DPI: u32 = 200;
pub const MIN_DPI: u32 = 72;
pub const MAX_DPI: u32 = 300;
pub const MAX_PIXELS: u64 = 24_000_000;
pub const MAX_IMAGE_BYTES: usize = 12 * 1024 * 1024;

static ASSET_ROOT: OnceLock<PathBuf> = OnceLock::new();
static CACHE_ROOT: OnceLock<PathBuf> = OnceLock::new();
type VerifiedAsset = (String, u64, SystemTime);
type VerifiedAssetCache = Mutex<HashMap<PathBuf, VerifiedAsset>>;
static VERIFIED_ASSETS: OnceLock<VerifiedAssetCache> = OnceLock::new();
static BATCH_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub fn default_source_asset_root() -> PathBuf {
    store_path()
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("source-assets")
}

pub fn source_asset_root() -> PathBuf {
    ASSET_ROOT
        .get()
        .cloned()
        .unwrap_or_else(default_source_asset_root)
}

pub fn source_cache_root() -> PathBuf {
    CACHE_ROOT
        .get()
        .cloned()
        .unwrap_or_else(|| source_asset_root().join("render-cache"))
}

pub fn set_source_asset_root(path: impl AsRef<Path>) -> Result<(), String> {
    ASSET_ROOT
        .set(path.as_ref().to_path_buf())
        .map_err(|_| "source asset root already set".into())
}

pub fn set_source_cache_root(path: impl AsRef<Path>) -> Result<(), String> {
    CACHE_ROOT
        .set(path.as_ref().to_path_buf())
        .map_err(|_| "source render cache root already set".into())
}

pub fn validate_sha256(hash: &str) -> Result<(), String> {
    if hash.len() == 64
        && hash
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err("source hash must be a lowercase SHA-256".into())
    }
}

/// Resolve a PDF only from a validated immutable hash. No caller-controlled
/// path component reaches the filesystem.
pub fn source_pdf_path(root: &Path, hash: &str) -> Result<PathBuf, String> {
    validate_sha256(hash)?;
    Ok(root.join(&hash[..2]).join(format!("{hash}.pdf")))
}

pub fn install_source_pdf(
    root: &Path,
    source: &Path,
    expected_hash: &str,
) -> Result<PathBuf, String> {
    validate_sha256(expected_hash)?;
    let bytes = std::fs::read(source).map_err(|error| format!("read source PDF: {error}"))?;
    let actual = format!("{:x}", Sha256::digest(&bytes));
    if actual != expected_hash {
        return Err("source PDF bytes do not match the catalogued source hash".into());
    }
    let destination = source_pdf_path(root, expected_hash)?;
    if destination.exists() {
        return Ok(destination);
    }
    let parent = destination
        .parent()
        .ok_or("asset destination has no parent")?;
    std::fs::create_dir_all(parent).map_err(|error| format!("create asset directory: {error}"))?;
    let temporary = parent.join(format!(".{expected_hash}.partial"));
    std::fs::write(&temporary, bytes).map_err(|error| format!("write source asset: {error}"))?;
    std::fs::rename(&temporary, &destination)
        .map_err(|error| format!("publish source asset: {error}"))?;
    remember_verified(&destination, expected_hash)?;
    Ok(destination)
}

/// Verify immutable bytes once per process and again whenever size or mtime
/// changes. This avoids hashing a large manual for every page/cache hit while
/// still detecting replacement after verification.
pub fn verify_source_pdf(path: &Path, expected_hash: &str) -> Result<(), String> {
    validate_sha256(expected_hash)?;
    let metadata = path
        .metadata()
        .map_err(|_| "immutable source PDF is unavailable".to_string())?;
    let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
    let verified = VERIFIED_ASSETS.get_or_init(|| Mutex::new(HashMap::new()));
    if verified
        .lock()
        .map_err(|_| "source verification cache is unavailable")?
        .get(path)
        .is_some_and(|(hash, size, time)| {
            hash == expected_hash && *size == metadata.len() && *time == modified
        })
    {
        return Ok(());
    }
    let bytes =
        std::fs::read(path).map_err(|_| "immutable source PDF is unavailable".to_string())?;
    if format!("{:x}", Sha256::digest(&bytes)) != expected_hash {
        return Err("stored source PDF failed its immutable hash check".into());
    }
    verified
        .lock()
        .map_err(|_| "source verification cache is unavailable")?
        .insert(
            path.to_path_buf(),
            (expected_hash.into(), metadata.len(), modified),
        );
    Ok(())
}

fn remember_verified(path: &Path, expected_hash: &str) -> Result<(), String> {
    let metadata = path.metadata().map_err(|error| error.to_string())?;
    VERIFIED_ASSETS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| "source verification cache is unavailable")?
        .insert(
            path.to_path_buf(),
            (
                expected_hash.into(),
                metadata.len(),
                metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH),
            ),
        );
    Ok(())
}

#[derive(Debug, Clone)]
pub struct RenderedPage {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub cache_hit: bool,
}

const RENDER_JXA: &str = r#"
function run(argv) {
  ObjC.import('Foundation'); ObjC.import('AppKit'); ObjC.import('Quartz');
  var input = argv[0], output = argv[1], index = parseInt(argv[2], 10), dpi = parseInt(argv[3], 10);
  var doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath($(input)));
  if (!doc || doc.isNil()) return JSON.stringify({error:'not a readable PDF'});
  var count = parseInt(doc.pageCount, 10);
  if (index < 0 || index >= count) return JSON.stringify({error:'page index out of range', pageCount:count});
  var page = doc.pageAtIndex(index), bounds = page.boundsForBox(0);
  var scale = dpi / 72.0, width = Math.max(1, Math.round(bounds.size.width * scale));
  var height = Math.max(1, Math.round(bounds.size.height * scale));
  if (width * height > 24000000) return JSON.stringify({error:'rendered page exceeds pixel limit'});
  var image = page.thumbnailOfSizeForBox({width:width, height:height}, 0);
  var rep = $.NSBitmapImageRep.imageRepWithData(image.TIFFRepresentation);
  var png = rep.representationUsingTypeProperties(4, $());
  if (!png || png.isNil()) return JSON.stringify({error:'PNG encoding failed'});
  if (!png.writeToFileAtomically($(output), true)) return JSON.stringify({error:'could not write PNG'});
  return JSON.stringify({pageCount:count,width:width,height:height});
}
"#;

const BATCH_RENDER_JXA: &str = r#"
function run(argv) {
  ObjC.import('Foundation'); ObjC.import('AppKit'); ObjC.import('Quartz');
  var input = argv[0], outputDir = argv[1], dpi = parseInt(argv[2], 10);
  var indexes = argv[3].split(',').filter(Boolean).map(function(value) { return parseInt(value, 10); });
  var doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath($(input)));
  if (!doc || doc.isNil()) return JSON.stringify({fatal:'not a readable PDF'});
  var count = parseInt(doc.pageCount, 10), results = [];
  indexes.forEach(function(index) {
    if (index < 0 || index >= count) {
      results.push({index:index,error:'page index out of range'}); return;
    }
    var page = doc.pageAtIndex(index), bounds = page.boundsForBox(0), scale = dpi / 72.0;
    var width = Math.max(1, Math.round(bounds.size.width * scale));
    var height = Math.max(1, Math.round(bounds.size.height * scale));
    if (width * height > 24000000) {
      results.push({index:index,error:'rendered page exceeds pixel limit'}); return;
    }
    var image = page.thumbnailOfSizeForBox({width:width, height:height}, 0);
    var rep = $.NSBitmapImageRep.imageRepWithData(image.TIFFRepresentation);
    var png = rep.representationUsingTypeProperties(4, $());
    var output = outputDir + '/' + index + '.png';
    if (!png || png.isNil() || !png.writeToFileAtomically($(output), true)) {
      results.push({index:index,error:'PNG encoding failed'}); return;
    }
    results.push({index:index,width:width,height:height});
  });
  return JSON.stringify({pageCount:count,results:results});
}
"#;

pub fn render_page(
    asset_root: &Path,
    cache_root: &Path,
    source_hash: &str,
    page_index: u32,
    dpi: u32,
    format: &str,
) -> Result<RenderedPage, String> {
    validate_render_request(dpi, format)?;
    let pdf = source_pdf_path(asset_root, source_hash)?;
    if !pdf.is_file() {
        return Err("immutable source PDF is unavailable".into());
    }
    verify_source_pdf(&pdf, source_hash)?;
    let key = page_cache_key(source_hash, page_index, dpi, format);
    let path = page_cache_path(cache_root, &key);
    if path.is_file() {
        return read_render(&path, true);
    }
    let parent = path.parent().ok_or("cache path has no parent")?;
    std::fs::create_dir_all(parent).map_err(|error| format!("create render cache: {error}"))?;
    let temporary = parent.join(format!(".{key}.partial"));
    let output = Command::new("osascript")
        .args([
            "-l",
            "JavaScript",
            "-e",
            RENDER_JXA,
            &pdf.to_string_lossy(),
            &temporary.to_string_lossy(),
            &page_index.to_string(),
            &dpi.to_string(),
        ])
        .output()
        .map_err(|error| format!("could not start PDFKit renderer: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "PDFKit renderer failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let report: serde_json::Value = serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("invalid PDFKit renderer response: {error}"))?;
    if let Some(error) = report.get("error").and_then(serde_json::Value::as_str) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error.into());
    }
    let rendered = read_render(&temporary, false)?;
    std::fs::rename(&temporary, &path).map_err(|error| format!("publish render cache: {error}"))?;
    Ok(rendered)
}

#[derive(Debug, Default)]
pub struct BatchRenderResult {
    pub pages: BTreeMap<u32, RenderedPage>,
    pub errors: BTreeMap<u32, String>,
}

/// Render many pages while opening the immutable PDF only once. Cached pages
/// are read directly; only misses cross the PDFKit boundary.
pub fn render_pages(
    asset_root: &Path,
    cache_root: &Path,
    source_hash: &str,
    page_indexes: &[u32],
    dpi: u32,
    format: &str,
) -> Result<BatchRenderResult, String> {
    validate_render_request(dpi, format)?;
    let pdf = source_pdf_path(asset_root, source_hash)?;
    if !pdf.is_file() {
        return Err("immutable source PDF is unavailable".into());
    }
    verify_source_pdf(&pdf, source_hash)?;
    let mut result = BatchRenderResult::default();
    let mut missing = Vec::new();
    for &page_index in page_indexes {
        let key = page_cache_key(source_hash, page_index, dpi, format);
        let path = page_cache_path(cache_root, &key);
        if path.is_file() {
            match read_render(&path, true) {
                Ok(page) => {
                    result.pages.insert(page_index, page);
                }
                Err(error) => {
                    result.errors.insert(page_index, error);
                }
            }
        } else if !missing.contains(&page_index) {
            missing.push(page_index);
        }
    }
    if missing.is_empty() {
        return Ok(result);
    }

    let sequence = BATCH_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let batch_dir = cache_root
        .join("batch")
        .join(format!("{}-{sequence}", std::process::id()));
    std::fs::create_dir_all(&batch_dir)
        .map_err(|error| format!("create batch render directory: {error}"))?;
    let indexes = missing
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let output = Command::new("osascript")
        .args([
            "-l",
            "JavaScript",
            "-e",
            BATCH_RENDER_JXA,
            &pdf.to_string_lossy(),
            &batch_dir.to_string_lossy(),
            &dpi.to_string(),
            &indexes,
        ])
        .output()
        .map_err(|error| format!("could not start batch PDFKit renderer: {error}"))?;
    if !output.status.success() {
        let _ = std::fs::remove_dir_all(&batch_dir);
        return Err(format!(
            "batch PDFKit renderer failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let report: serde_json::Value = serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("invalid batch PDFKit response: {error}"))?;
    if let Some(error) = report.get("fatal").and_then(serde_json::Value::as_str) {
        let _ = std::fs::remove_dir_all(&batch_dir);
        return Err(error.into());
    }
    for entry in report
        .get("results")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(page_index) = entry
            .get("index")
            .and_then(serde_json::Value::as_u64)
            .map(|value| value as u32)
        else {
            continue;
        };
        if let Some(error) = entry.get("error").and_then(serde_json::Value::as_str) {
            result.errors.insert(page_index, error.into());
            continue;
        }
        let temporary = batch_dir.join(format!("{page_index}.png"));
        match read_render(&temporary, false) {
            Ok(page) => {
                let key = page_cache_key(source_hash, page_index, dpi, format);
                let cache = page_cache_path(cache_root, &key);
                if let Some(parent) = cache.parent() {
                    std::fs::create_dir_all(parent)
                        .map_err(|error| format!("create page cache: {error}"))?;
                }
                std::fs::rename(&temporary, &cache)
                    .map_err(|error| format!("publish batch page cache: {error}"))?;
                result.pages.insert(page_index, page);
            }
            Err(error) => {
                result.errors.insert(page_index, error);
            }
        }
    }
    let _ = std::fs::remove_dir_all(&batch_dir);
    Ok(result)
}

pub struct FigureCropSpec<'a> {
    pub source_hash: &'a str,
    pub page_index: u32,
    pub bounds: (u32, u32, u32, u32),
    pub padding: u32,
    pub dpi: u32,
    pub include_caption: bool,
}

pub fn crop_page(
    cache_root: &Path,
    page: &RenderedPage,
    spec: &FigureCropSpec<'_>,
) -> Result<RenderedPage, String> {
    let (x, y, width, height) = spec.bounds;
    if width == 0
        || height == 0
        || x.saturating_add(width) > page.width
        || y.saturating_add(height) > page.height
    {
        return Err("figure crop is outside rendered page bounds".into());
    }
    let key = cache_key(&format!(
        "figure:{}:{}:{x}:{y}:{width}:{height}:{}:{}:{}:png",
        spec.source_hash, spec.page_index, spec.padding, spec.dpi, spec.include_caption
    ));
    let path = cache_root
        .join("figures")
        .join(&key[..2])
        .join(format!("{key}.png"));
    if path.is_file() {
        return read_render(&path, true);
    }
    let left = x.saturating_sub(spec.padding);
    let top = y.saturating_sub(spec.padding);
    let right = x
        .saturating_add(width)
        .saturating_add(spec.padding)
        .min(page.width);
    let bottom = y
        .saturating_add(height)
        .saturating_add(spec.padding)
        .min(page.height);
    let image = image::load_from_memory_with_format(&page.png, image::ImageFormat::Png)
        .map_err(|error| format!("decode rendered page: {error}"))?;
    let crop = image.crop_imm(left, top, right - left, bottom - top);
    let parent = path.parent().ok_or("figure cache path has no parent")?;
    std::fs::create_dir_all(parent).map_err(|error| format!("create figure cache: {error}"))?;
    let temporary = parent.join(format!(".{key}.partial"));
    crop.save_with_format(&temporary, image::ImageFormat::Png)
        .map_err(|error| format!("encode figure crop: {error}"))?;
    let rendered = read_render(&temporary, false)?;
    std::fs::rename(&temporary, &path).map_err(|error| format!("publish figure cache: {error}"))?;
    Ok(rendered)
}

fn validate_render_request(dpi: u32, format: &str) -> Result<(), String> {
    if !(MIN_DPI..=MAX_DPI).contains(&dpi) {
        return Err(format!(
            "resolution_dpi must be between {MIN_DPI} and {MAX_DPI}"
        ));
    }
    if format != "png" {
        return Err("only deterministic PNG output is currently supported".into());
    }
    Ok(())
}

fn page_cache_key(source_hash: &str, page_index: u32, dpi: u32, format: &str) -> String {
    cache_key(&format!("page:{source_hash}:{page_index}:{dpi}:{format}"))
}

fn page_cache_path(cache_root: &Path, key: &str) -> PathBuf {
    cache_root
        .join("pages")
        .join(&key[..2])
        .join(format!("{key}.png"))
}

fn read_render(path: &Path, cache_hit: bool) -> Result<RenderedPage, String> {
    let png = std::fs::read(path).map_err(|error| format!("read rendered image: {error}"))?;
    if png.len() > MAX_IMAGE_BYTES {
        return Err(format!(
            "rendered image exceeds {} byte limit",
            MAX_IMAGE_BYTES
        ));
    }
    let image = image::load_from_memory_with_format(&png, image::ImageFormat::Png)
        .map_err(|error| format!("validate rendered PNG: {error}"))?;
    let (width, height) = image.dimensions();
    if u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err("rendered image exceeds pixel limit".into());
    }
    Ok(RenderedPage {
        png,
        width,
        height,
        cache_hit,
    })
}

fn cache_key(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asset_paths_cannot_traverse() {
        assert!(source_pdf_path(Path::new("/tmp/assets"), "../../etc/passwd").is_err());
        let hash = "a".repeat(64);
        assert_eq!(
            source_pdf_path(Path::new("/tmp/assets"), &hash).unwrap(),
            Path::new("/tmp/assets/aa").join(format!("{hash}.pdf"))
        );
    }

    #[test]
    fn dpi_and_format_are_bounded() {
        assert!(validate_render_request(71, "png").is_err());
        assert!(validate_render_request(301, "png").is_err());
        assert!(validate_render_request(150, "jpeg").is_err());
        assert!(validate_render_request(150, "png").is_ok());
    }

    #[test]
    fn returned_byte_size_is_bounded_before_decode() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("too-large.png");
        std::fs::write(&path, vec![0_u8; MAX_IMAGE_BYTES + 1]).unwrap();
        assert!(read_render(&path, false)
            .unwrap_err()
            .contains("byte limit"));
    }
}
