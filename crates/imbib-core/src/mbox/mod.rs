//! imbib's mbox archive format: RFC 2045/2047 decoding and message splitting.
//!
//! Stage 7 item 9. Ported from `PublicationManagerCore/Mbox/MIMEDecoder.swift`
//! and `MboxParser.swift`; the Swift files are now shims over the FFI in
//! `crate::parsers_ffi`. See `docs/parser-batch-swift-rust-split.md` for where the line is
//! drawn against `impart-core::mbox` (a different format with a different
//! contract) and for the round-trip corruption the golden corpus surfaced.

pub mod mime;
pub mod parser;

pub use mime::{
    base64_decode, base_content_type, charset_of, decode_header_value, decode_header_value_swift,
    decode_latin1, decode_multipart, decode_text, encoding_for_charset, extract_boundary,
    extract_parameter, quoted_printable_decode, quoted_printable_decode_swift,
    quoted_printable_tokens, render_swift_latin1, render_text, unescape_from_lines, MimePart,
    QpToken,
};
pub use parser::{parse_content, MboxAttachment, MboxMessage};
