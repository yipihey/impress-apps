//! Transports and file formats for reMarkable tablets.
//!
//! reMarkable's cloud is not the only way to reach a tablet, and since the
//! company retired the `document-storage/json/2` API it is not a working one
//! either. On current firmware the transport that works without any
//! credential is the tablet's own USB web interface ([`usb_web`]); the
//! archive it hands back is parsed by [`rmdoc`]. The SFTP transport below
//! remains for tablets whose SSH server is reachable. Every tablet runs Linux with an SSH server on its Wi-Fi interface,
//! and its documents are plain files under one directory, so a researcher on
//! the same network can move papers and annotations without a cloud round
//! trip. That is what this crate does.
//!
//! What the tablet requires, and the caller must surface:
//!
//! * the tablet awake and on Wi-Fi (it drops the network in standby);
//! * its address and root password, both printed on the tablet under
//!   Settings → Help → Copyrights and licenses.
//!
//! Host keys are trust-on-first-use: [`probe`] reports the fingerprint it saw,
//! and later calls can pin it by setting [`DeviceCredentials::fingerprint`].
//! A tablet that presents a different key then fails loudly rather than
//! silently handing a password to whatever answered on that address.

mod documents;
mod error;
pub mod rm;
pub mod rmdoc;
mod transport;
pub mod usb_web;

pub mod blocking;

pub use documents::{DocumentKind, RemarkableDocument, XochitlContent, XochitlMetadata};
pub use error::{Error, Result};
pub use rm::{parse_rm, GlyphRange, Line, RmScene, RootText, Tool};
pub use rmdoc::{
    RmContent, RmDocumentArchive, RmPage, RmdocKind, RmdocSpec, SourceDocument, SourceKind,
};
pub use transport::{
    download_document, list_documents, probe, restart_ui, DeviceCredentials, DeviceInfo,
    DownloadedDocument, XOCHITL_DIRECTORY,
};
pub use usb_web::{DownloadKind, UploadReceipt};
