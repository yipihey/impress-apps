//! SFTP over the tablet's own SSH server.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use russh::client;
use russh_keys::key::PublicKey;
use russh_sftp::client::SftpSession;
use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;

use crate::documents::{parse_content, parse_metadata, RemarkableDocument};
use crate::error::{Error, Result};

/// Where xochitl keeps every document. Stable across firmware for years.
pub const XOCHITL_DIRECTORY: &str = "/home/root/.local/share/remarkable/xochitl";

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const INACTIVITY_TIMEOUT: Duration = Duration::from_secs(60);

/// How to reach one tablet.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceCredentials {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: String,
    /// Pinned host-key fingerprint. `None` trusts whatever answers, which is
    /// right only for the first connection; store what [`probe`] returned and
    /// pass it back afterwards.
    pub fingerprint: Option<String>,
}

impl DeviceCredentials {
    /// The tablet's defaults: root over port 22.
    pub fn new(host: impl Into<String>, password: impl Into<String>) -> Self {
        Self {
            host: host.into(),
            port: 22,
            username: "root".into(),
            password: password.into(),
            fingerprint: None,
        }
    }
}

/// What answered, and what it is.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub host: String,
    /// The host key we saw. Pin this in later calls.
    pub fingerprint: String,
    /// Contents of `/etc/version`, when the tablet has one.
    pub firmware: Option<String>,
    /// Entries under the xochitl directory, folders included.
    pub document_count: u32,
}

/// A document pulled off the tablet.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadedDocument {
    pub id: String,
    /// The original PDF or EPUB, when the document has one.
    pub source_path: Option<String>,
    /// Per-page `.rm` stroke files, in page order where the names allow it.
    pub annotation_paths: Vec<String>,
}

/// Records the host key so trust-on-first-use can report it, and refuses a
/// key that differs from one already pinned.
struct KeyRecorder {
    expected: Option<String>,
    seen: Arc<Mutex<Option<String>>>,
    mismatch: Arc<Mutex<Option<String>>>,
}

#[async_trait::async_trait]
impl client::Handler for KeyRecorder {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> std::result::Result<bool, Self::Error> {
        let fingerprint = server_public_key.fingerprint();
        *self.seen.lock().unwrap() = Some(fingerprint.clone());
        match &self.expected {
            // The password must not leave this machine when the key changed:
            // whatever is on that address now is not what we paired with.
            Some(expected) if expected != &fingerprint => {
                *self.mismatch.lock().unwrap() = Some(fingerprint);
                Ok(false)
            }
            _ => Ok(true),
        }
    }
}

struct Session {
    handle: client::Handle<KeyRecorder>,
    fingerprint: String,
}

async fn connect(credentials: &DeviceCredentials) -> Result<Session> {
    let seen = Arc::new(Mutex::new(None));
    let mismatch = Arc::new(Mutex::new(None));
    let handler = KeyRecorder {
        expected: credentials.fingerprint.clone(),
        seen: Arc::clone(&seen),
        mismatch: Arc::clone(&mismatch),
    };

    let config = Arc::new(client::Config {
        inactivity_timeout: Some(INACTIVITY_TIMEOUT),
        ..Default::default()
    });

    let address = (credentials.host.as_str(), credentials.port);
    let connecting = client::connect(config, address, handler);
    let mut handle = match tokio::time::timeout(CONNECT_TIMEOUT, connecting).await {
        Ok(Ok(handle)) => handle,
        Ok(Err(error)) => {
            if let Some(actual) = mismatch.lock().unwrap().clone() {
                return Err(Error::HostKeyChanged {
                    host: credentials.host.clone(),
                    expected: credentials.fingerprint.clone().unwrap_or_default(),
                    actual,
                });
            }
            return Err(Error::Unreachable {
                host: credentials.host.clone(),
                port: credentials.port,
                detail: error.to_string(),
            });
        }
        Err(_) => {
            return Err(Error::Unreachable {
                host: credentials.host.clone(),
                port: credentials.port,
                detail: "timed out — the tablet drops Wi-Fi in standby, so wake it first".into(),
            })
        }
    };

    let authenticated = handle
        .authenticate_password(&credentials.username, &credentials.password)
        .await
        .map_err(|error| Error::transport(&credentials.host, "authentication", error))?;
    if !authenticated {
        return Err(Error::Authentication {
            host: credentials.host.clone(),
            username: credentials.username.clone(),
        });
    }

    let fingerprint = seen.lock().unwrap().clone().unwrap_or_default();
    Ok(Session {
        handle,
        fingerprint,
    })
}

async fn open_sftp(session: &Session, host: &str) -> Result<SftpSession> {
    let channel = session
        .handle
        .channel_open_session()
        .await
        .map_err(|error| Error::transport(host, "opening a channel", error))?;
    channel
        .request_subsystem(true, "sftp")
        .await
        .map_err(|error| Error::transport(host, "requesting the sftp subsystem", error))?;
    SftpSession::new(channel.into_stream())
        .await
        .map_err(|error| Error::transport(host, "starting sftp", error))
}

async fn read_file(sftp: &SftpSession, path: &str) -> Option<Vec<u8>> {
    let mut file = sftp.open(path).await.ok()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).await.ok()?;
    Some(bytes)
}

/// Reach the tablet, confirm it is one, and report its host key.
pub async fn probe(credentials: &DeviceCredentials) -> Result<DeviceInfo> {
    let session = connect(credentials).await?;
    let sftp = open_sftp(&session, &credentials.host).await?;

    let entries = sftp.read_dir(XOCHITL_DIRECTORY).await.map_err(|error| {
        // A tablet always has this directory; anything else that answers SSH
        // on the network does not, and saying so beats a generic failure.
        Error::NotARemarkable {
            host: credentials.host.clone(),
            detail: format!("{XOCHITL_DIRECTORY} is not readable ({error})"),
        }
    })?;

    let document_count = entries
        .filter(|entry| entry.file_name().ends_with(".metadata"))
        .count() as u32;
    let firmware = read_file(&sftp, "/etc/version")
        .await
        .map(|bytes| String::from_utf8_lossy(&bytes).trim().to_string())
        .filter(|version| !version.is_empty());

    Ok(DeviceInfo {
        host: credentials.host.clone(),
        fingerprint: session.fingerprint,
        firmware,
        document_count,
    })
}

/// Every document on the tablet, deleted ones excluded.
pub async fn list_documents(credentials: &DeviceCredentials) -> Result<Vec<RemarkableDocument>> {
    let session = connect(credentials).await?;
    let sftp = open_sftp(&session, &credentials.host).await?;

    let entries: Vec<String> = sftp
        .read_dir(XOCHITL_DIRECTORY)
        .await
        .map_err(|error| Error::NotARemarkable {
            host: credentials.host.clone(),
            detail: format!("{XOCHITL_DIRECTORY} is not readable ({error})"),
        })?
        .map(|entry| entry.file_name())
        .collect();

    let ids: Vec<String> = entries
        .iter()
        .filter_map(|name| name.strip_suffix(".metadata").map(str::to_string))
        .collect();
    let directories: std::collections::HashSet<&String> = entries.iter().collect();

    let mut documents = Vec::with_capacity(ids.len());
    for id in ids {
        let Some(bytes) = read_file(&sftp, &format!("{XOCHITL_DIRECTORY}/{id}.metadata")).await
        else {
            continue;
        };
        let Some(metadata) = parse_metadata(&bytes) else {
            continue; // deleted, or unreadable
        };
        let content = read_file(&sftp, &format!("{XOCHITL_DIRECTORY}/{id}.content"))
            .await
            .and_then(|bytes| parse_content(&bytes));
        let has_annotations = directories.contains(&id);
        documents.push(RemarkableDocument::from_files(
            &id,
            &metadata,
            content.as_ref(),
            has_annotations,
        ));
    }
    // Newest first: the document the researcher just annotated is the one
    // they are looking for.
    documents.sort_by_key(|document| std::cmp::Reverse(document.last_modified_ms));
    Ok(documents)
}

/// Pull one document's source file and its stroke files into `destination`.
pub async fn download_document(
    credentials: &DeviceCredentials,
    id: &str,
    destination: &Path,
) -> Result<DownloadedDocument> {
    let session = connect(credentials).await?;
    let sftp = open_sftp(&session, &credentials.host).await?;

    let metadata_path = format!("{XOCHITL_DIRECTORY}/{id}.metadata");
    if read_file(&sftp, &metadata_path).await.is_none() {
        return Err(Error::DocumentNotFound {
            host: credentials.host.clone(),
            id: id.to_string(),
        });
    }

    std::fs::create_dir_all(destination).map_err(|error| Error::Io {
        path: destination.display().to_string(),
        detail: error.to_string(),
    })?;

    let mut source_path = None;
    for extension in ["pdf", "epub"] {
        let remote = format!("{XOCHITL_DIRECTORY}/{id}.{extension}");
        if let Some(bytes) = read_file(&sftp, &remote).await {
            let local: PathBuf = destination.join(format!("{id}.{extension}"));
            write_local(&local, &bytes)?;
            source_path = Some(local.display().to_string());
            break;
        }
    }

    let mut annotation_paths = Vec::new();
    if let Ok(entries) = sftp.read_dir(format!("{XOCHITL_DIRECTORY}/{id}")).await {
        let mut names: Vec<String> = entries
            .map(|entry| entry.file_name())
            .filter(|name| name.ends_with(".rm"))
            .collect();
        names.sort();
        for name in names {
            let remote = format!("{XOCHITL_DIRECTORY}/{id}/{name}");
            if let Some(bytes) = read_file(&sftp, &remote).await {
                let local = destination.join(&name);
                write_local(&local, &bytes)?;
                annotation_paths.push(local.display().to_string());
            }
        }
    }

    Ok(DownloadedDocument {
        id: id.to_string(),
        source_path,
        annotation_paths,
    })
}

fn write_local(path: &Path, bytes: &[u8]) -> Result<()> {
    std::fs::write(path, bytes).map_err(|error| Error::Io {
        path: path.display().to_string(),
        detail: error.to_string(),
    })
}

/// Restart the tablet's UI so it notices files written underneath it.
pub async fn restart_ui(credentials: &DeviceCredentials) -> Result<()> {
    let session = connect(credentials).await?;
    let channel = session
        .handle
        .channel_open_session()
        .await
        .map_err(|error| Error::transport(&credentials.host, "opening a channel", error))?;
    channel
        .exec(true, "systemctl restart xochitl")
        .await
        .map_err(|error| Error::transport(&credentials.host, "restarting xochitl", error))?;
    Ok(())
}
