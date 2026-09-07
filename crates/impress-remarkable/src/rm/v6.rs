//! Firmware-3 `.lines` files (version 6): a stream of length-prefixed
//! blocks, each a tagged-value record (the layout `rmscene` documents).
//!
//! Block header: `u32 length, u8 0, u8 min_version, u8 current_version,
//! u8 block_type`, then `length` bytes. Inside, every field is a tag
//! (`varuint`: index << 4 | type) followed by a value whose shape the type
//! names: `1` one byte, `4` four bytes, `8` eight bytes, `C` a
//! length-prefixed sub-block, `F` a CRDT id (`u8` + `varuint`). Fields
//! are read by index, so an unknown field is skipped by its type and a
//! missing optional field is simply absent; whole blocks of a type this
//! reader does not know are recorded in `skipped_blocks` and passed over.

use super::{CrdtId, GlyphRange, Line, Paragraph, Point, Rect, RmScene, RootText, Tool};
use crate::error::{Error, Result};

const TAG_BYTE1: u8 = 0x1;
const TAG_BYTE4: u8 = 0x4;
const TAG_BYTE8: u8 = 0x8;
const TAG_LENGTH4: u8 = 0xC;
const TAG_ID: u8 = 0xF;

const BLOCK_GLYPH_ITEM: u8 = 0x03;
const BLOCK_GROUP_ITEM: u8 = 0x04;
const BLOCK_LINE_ITEM: u8 = 0x05;
const BLOCK_TEXT_ITEM: u8 = 0x06;
const BLOCK_ROOT_TEXT: u8 = 0x07;

const ITEM_GLYPH_RANGE: u8 = 1;
const ITEM_GROUP: u8 = 2;
const ITEM_LINE: u8 = 3;
const ITEM_TEXT: u8 = 5;

fn format_error(detail: impl Into<String>) -> Error {
    Error::Format {
        path: "<rm v6>".into(),
        detail: detail.into(),
    }
}

/// A cursor over one block (or sub-block).
struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, pos: 0 }
    }

    fn remaining(&self) -> usize {
        self.bytes.len() - self.pos
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.pos + n > self.bytes.len() {
            return Err(format_error(format!(
                "truncated at byte {} (wanted {n} more of {})",
                self.pos,
                self.bytes.len()
            )));
        }
        let slice = &self.bytes[self.pos..self.pos + n];
        self.pos += n;
        Ok(slice)
    }

    fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }

    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn f32(&mut self) -> Result<f32> {
        Ok(f32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn f64(&mut self) -> Result<f64> {
        Ok(f64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    fn varuint(&mut self) -> Result<u64> {
        let mut result: u64 = 0;
        let mut shift = 0;
        loop {
            let byte = self.u8()?;
            result |= u64::from(byte & 0x7f) << shift;
            if byte & 0x80 == 0 {
                return Ok(result);
            }
            shift += 7;
            if shift > 63 {
                return Err(format_error("varuint too long"));
            }
        }
    }

    fn id(&mut self) -> Result<CrdtId> {
        Ok(CrdtId {
            part1: self.u8()?,
            part2: self.varuint()?,
        })
    }

    /// Look at the next tag without consuming it.
    fn peek_tag(&self) -> Option<(u64, u8)> {
        let mut probe = Reader {
            bytes: self.bytes,
            pos: self.pos,
        };
        if probe.remaining() == 0 {
            return None;
        }
        let tag = probe.varuint().ok()?;
        Some((tag >> 4, (tag & 0xf) as u8))
    }

    fn read_tag(&mut self) -> Result<(u64, u8)> {
        let tag = self.varuint()?;
        Ok((tag >> 4, (tag & 0xf) as u8))
    }

    /// Skip one value of the given type.
    fn skip_value(&mut self, kind: u8) -> Result<()> {
        match kind {
            TAG_BYTE1 => self.take(1).map(|_| ()),
            TAG_BYTE4 => self.take(4).map(|_| ()),
            TAG_BYTE8 => self.take(8).map(|_| ()),
            TAG_LENGTH4 => {
                let length = self.u32()? as usize;
                self.take(length).map(|_| ())
            }
            TAG_ID => self.id().map(|_| ()),
            other => Err(format_error(format!("unknown tag type {other:#x}"))),
        }
    }

    /// Skip fields until the one with `index` is next (or nothing is left).
    fn seek_index(&mut self, index: u64) -> Result<bool> {
        while let Some((next_index, kind)) = self.peek_tag() {
            if next_index == index {
                return Ok(true);
            }
            if next_index > index {
                return Ok(false);
            }
            self.read_tag()?;
            self.skip_value(kind)?;
        }
        Ok(false)
    }

    fn expect(&mut self, index: u64, kind: u8) -> Result<bool> {
        if !self.seek_index(index)? {
            return Ok(false);
        }
        let (_, actual) = self.read_tag()?;
        if actual != kind {
            return Err(format_error(format!(
                "field {index} has type {actual:#x}, expected {kind:#x}"
            )));
        }
        Ok(true)
    }

    fn opt_u32(&mut self, index: u64) -> Result<Option<u32>> {
        Ok(if self.expect(index, TAG_BYTE4)? {
            Some(self.u32()?)
        } else {
            None
        })
    }

    fn opt_f32(&mut self, index: u64) -> Result<Option<f32>> {
        Ok(if self.expect(index, TAG_BYTE4)? {
            Some(self.f32()?)
        } else {
            None
        })
    }

    fn opt_f64(&mut self, index: u64) -> Result<Option<f64>> {
        Ok(if self.expect(index, TAG_BYTE8)? {
            Some(self.f64()?)
        } else {
            None
        })
    }

    fn opt_id(&mut self, index: u64) -> Result<Option<CrdtId>> {
        Ok(if self.expect(index, TAG_ID)? {
            Some(self.id()?)
        } else {
            None
        })
    }

    fn opt_subblock(&mut self, index: u64) -> Result<Option<Reader<'a>>> {
        if !self.expect(index, TAG_LENGTH4)? {
            return Ok(None);
        }
        let length = self.u32()? as usize;
        Ok(Some(Reader::new(self.take(length)?)))
    }

    /// A length-prefixed string: `varuint length, u8 is_ascii, bytes`.
    fn string(&mut self) -> Result<String> {
        let length = self.varuint()? as usize;
        let _is_ascii = self.u8()?;
        let bytes = self.take(length)?;
        Ok(String::from_utf8_lossy(bytes).into_owned())
    }
}

struct ItemHeader {
    item_id: CrdtId,
    deleted_length: u32,
}

/// The common prefix of every scene-item block.
fn item_header(reader: &mut Reader<'_>) -> Result<ItemHeader> {
    let _parent = reader.opt_id(1)?;
    let item_id = reader
        .opt_id(2)?
        .ok_or_else(|| format_error("scene item without an id"))?;
    let _left = reader.opt_id(3)?;
    let _right = reader.opt_id(4)?;
    let deleted_length = reader.opt_u32(5)?.unwrap_or(0);
    Ok(ItemHeader {
        item_id,
        deleted_length,
    })
}

fn read_points(reader: &mut Reader<'_>, block_version: u8) -> Result<Vec<Point>> {
    let point_size = if block_version >= 2 { 14 } else { 24 };
    let count = reader.remaining() / point_size;
    let mut points = Vec::with_capacity(count);
    for _ in 0..count {
        let point = if block_version >= 2 {
            let x = reader.f32()?;
            let y = reader.f32()?;
            let speed = f32::from(reader.u16()?);
            let width = f32::from(reader.u16()?);
            let direction = f32::from(reader.u8()?);
            let pressure = f32::from(reader.u8()?) / 255.0;
            Point {
                x,
                y,
                speed,
                direction,
                width,
                pressure,
            }
        } else {
            Point {
                x: reader.f32()?,
                y: reader.f32()?,
                speed: reader.f32()?,
                direction: reader.f32()?,
                width: reader.f32()?,
                pressure: reader.f32()?,
            }
        };
        points.push(point);
    }
    Ok(points)
}

fn read_line(reader: &mut Reader<'_>, id: CrdtId, block_version: u8) -> Result<Line> {
    let tool = reader.opt_u32(1)?.unwrap_or(0);
    let color = reader.opt_u32(2)?.unwrap_or(0);
    let thickness_scale = reader.opt_f64(3)?.unwrap_or(1.0);
    let _starting_length = reader.opt_f32(4)?;
    let points = match reader.opt_subblock(5)? {
        Some(mut points) => read_points(&mut points, block_version)?,
        None => Vec::new(),
    };
    let _timestamp = reader.opt_id(6)?;
    let _move_id = reader.opt_id(7)?;
    let rgba = reader.opt_u32(8)?;
    Ok(Line {
        id: Some(id),
        layer: 0,
        tool: Tool::from_id(tool),
        color,
        rgba,
        thickness_scale,
        points,
    })
}

fn read_glyph_range(reader: &mut Reader<'_>, id: CrdtId) -> Result<GlyphRange> {
    let start = reader.opt_u32(2)?.unwrap_or(0);
    let length = reader.opt_u32(3)?.unwrap_or(0);
    let color = reader.opt_u32(4)?.unwrap_or(0);
    let text = match reader.opt_subblock(5)? {
        Some(mut sub) => sub.string()?,
        None => String::new(),
    };
    let mut rects = Vec::new();
    if let Some(mut sub) = reader.opt_subblock(6)? {
        if sub.remaining() == 32 {
            rects.push(Rect {
                x: sub.f64()?,
                y: sub.f64()?,
                w: sub.f64()?,
                h: sub.f64()?,
            });
        } else {
            let count = sub.varuint()?;
            for _ in 0..count {
                if sub.remaining() < 32 {
                    break;
                }
                rects.push(Rect {
                    x: sub.f64()?,
                    y: sub.f64()?,
                    w: sub.f64()?,
                    h: sub.f64()?,
                });
            }
        }
    }
    Ok(GlyphRange {
        id,
        start,
        length,
        color,
        text,
        rects,
    })
}

/// One item of the typed-text CRDT sequence: a string (possibly with a
/// paragraph-style code) or a tombstone.
struct TextItem {
    left: CrdtId,
    id: CrdtId,
    value: Option<String>,
    style: Option<u8>,
}

fn read_text_item(reader: &mut Reader<'_>) -> Result<TextItem> {
    let mut sub = reader
        .opt_subblock(0)?
        .ok_or_else(|| format_error("text item without a sub-block"))?;
    let id = sub
        .opt_id(2)?
        .ok_or_else(|| format_error("text item without an id"))?;
    let left = sub.opt_id(3)?.unwrap_or_default();
    let _right = sub.opt_id(4)?;
    let _deleted_length = sub.opt_u32(5)?.unwrap_or(0);
    let mut value = None;
    let mut style = None;
    if let Some(mut payload) = sub.opt_subblock(6)? {
        let text = payload.string()?;
        if payload.remaining() >= 5 {
            // A format code follows the string on paragraph breaks.
            if let Some((2, TAG_BYTE4)) = payload.peek_tag() {
                payload.read_tag()?;
                style = Some(payload.u32()? as u8);
            }
        }
        value = Some(text);
    }
    Ok(TextItem {
        left,
        id,
        value,
        style,
    })
}

fn read_root_text(reader: &mut Reader<'_>) -> Result<RootText> {
    let id = reader.opt_id(1)?.unwrap_or_default();
    let mut items: Vec<TextItem> = Vec::new();
    let mut styles: Vec<(CrdtId, u8)> = Vec::new();
    if let Some(mut outer) = reader.opt_subblock(2)? {
        if let Some(mut seq) = outer.opt_subblock(1)? {
            if let Some(mut inner) = seq.opt_subblock(1)? {
                let count = inner.varuint()?;
                for _ in 0..count {
                    items.push(read_text_item(&mut inner)?);
                }
            }
        }
        if let Some(mut fmt) = outer.opt_subblock(2)? {
            if let Some(mut inner) = fmt.opt_subblock(1)? {
                let count = inner.varuint()?;
                for _ in 0..count {
                    let char_id = inner.id()?;
                    let _timestamp = inner.opt_id(1)?;
                    if let Some(mut sub) = inner.opt_subblock(2)? {
                        let _marker = sub.u8()?;
                        let code = sub.u8()?;
                        styles.push((char_id, code));
                    }
                }
            }
        }
    }
    let (pos_x, pos_y) = match reader.opt_subblock(3)? {
        Some(mut sub) => (sub.f64()?, sub.f64()?),
        None => (0.0, 0.0),
    };
    let width = reader.opt_f32(4)?.unwrap_or(0.0);

    let default_style = styles.first().map(|(_, code)| *code).unwrap_or(0);
    let paragraphs = paragraphs_of(&order_text(&items), default_style);
    Ok(RootText {
        id,
        paragraphs,
        pos_x,
        pos_y,
        width,
    })
}

/// Split the ordered items into paragraphs: a `\n` ends one, and the style
/// code that travels with that item styles the paragraph it closes.
fn paragraphs_of(ordered: &[&TextItem], default_style: u8) -> Vec<Paragraph> {
    let mut paragraphs = Vec::new();
    let mut current = String::new();
    for item in ordered {
        let Some(value) = &item.value else { continue };
        for (index, piece) in value.split('\n').enumerate() {
            if index > 0 {
                paragraphs.push(Paragraph {
                    style: item.style.unwrap_or(default_style),
                    text: std::mem::take(&mut current),
                });
            }
            current.push_str(piece);
        }
    }
    if !current.is_empty() || paragraphs.is_empty() {
        paragraphs.push(Paragraph {
            style: default_style,
            text: current,
        });
    }
    paragraphs
}

/// Lay the CRDT sequence out: each item follows the item its `left` names;
/// items whose left is unknown keep file order. Tombstones contribute
/// nothing.
fn order_text(items: &[TextItem]) -> Vec<&TextItem> {
    let mut ordered: Vec<&TextItem> = Vec::with_capacity(items.len());
    let mut remaining: Vec<&TextItem> = items.iter().collect();
    // Start with items anchored at the origin, in file order.
    let mut anchor = CrdtId::default();
    loop {
        let position = remaining
            .iter()
            .position(|item| item.left == anchor)
            .or_else(|| (!ordered.is_empty() || remaining.is_empty()).then_some(0));
        let Some(position) = position else {
            // Nothing anchored at the origin: keep file order.
            break;
        };
        if remaining.is_empty() {
            break;
        }
        let item = remaining.remove(position);
        anchor = item.id;
        ordered.push(item);
    }
    ordered.extend(remaining);
    ordered
}

pub(super) fn parse(body: &[u8]) -> Result<RmScene> {
    let mut scene = RmScene {
        version: 6,
        layer_count: 1,
        ..Default::default()
    };
    let mut reader = Reader::new(body);
    while reader.remaining() > 0 {
        if reader.remaining() < 8 {
            scene
                .warnings
                .push(format!("{} trailing byte(s)", reader.remaining()));
            break;
        }
        let length = reader.u32()? as usize;
        let _unknown = reader.u8()?;
        let _min_version = reader.u8()?;
        let current_version = reader.u8()?;
        let block_type = reader.u8()?;
        let data = reader.take(length)?;
        let mut block = Reader::new(data);
        match block_type {
            BLOCK_LINE_ITEM | BLOCK_GLYPH_ITEM | BLOCK_GROUP_ITEM | BLOCK_TEXT_ITEM => {
                let header = item_header(&mut block)?;
                let Some(mut value) = block.opt_subblock(6)? else {
                    // A tombstone: the item was deleted.
                    continue;
                };
                if header.deleted_length > 0 && value.remaining() == 0 {
                    continue;
                }
                let item_type = value.u8()?;
                match item_type {
                    ITEM_LINE => {
                        let line = read_line(&mut value, header.item_id, current_version)?;
                        scene.lines.push(line);
                    }
                    ITEM_GLYPH_RANGE => {
                        let glyph = read_glyph_range(&mut value, header.item_id)?;
                        scene.glyph_ranges.push(glyph);
                    }
                    ITEM_GROUP | ITEM_TEXT => {}
                    other => scene
                        .warnings
                        .push(format!("unknown scene item type {other}")),
                }
            }
            BLOCK_ROOT_TEXT => {
                let root = read_root_text(&mut block)?;
                scene.root_text = Some(root);
            }
            other => {
                if !scene.skipped_blocks.contains(&other) {
                    scene.skipped_blocks.push(other);
                }
            }
        }
    }
    Ok(scene)
}

#[cfg(test)]
mod tests {
    use super::super::{parse_rm, Tool, HEADER_LEN};
    use super::*;

    /// A tiny writer mirroring the reader, so the synthetic fixtures are
    /// built from the same grammar the tests assert.
    struct Writer(Vec<u8>);

    impl Writer {
        fn varuint(&mut self, mut value: u64) {
            loop {
                let byte = (value & 0x7f) as u8;
                value >>= 7;
                if value == 0 {
                    self.0.push(byte);
                    return;
                }
                self.0.push(byte | 0x80);
            }
        }
        fn tag(&mut self, index: u64, kind: u8) {
            self.varuint(index << 4 | u64::from(kind));
        }
        fn id(&mut self, index: u64, id: CrdtId) {
            self.tag(index, TAG_ID);
            self.0.push(id.part1);
            self.varuint(id.part2);
        }
        fn u32(&mut self, index: u64, value: u32) {
            self.tag(index, TAG_BYTE4);
            self.0.extend_from_slice(&value.to_le_bytes());
        }
        fn f32(&mut self, index: u64, value: f32) {
            self.tag(index, TAG_BYTE4);
            self.0.extend_from_slice(&value.to_le_bytes());
        }
        fn f64(&mut self, index: u64, value: f64) {
            self.tag(index, TAG_BYTE8);
            self.0.extend_from_slice(&value.to_le_bytes());
        }
        fn sub(&mut self, index: u64, inner: &[u8]) {
            self.tag(index, TAG_LENGTH4);
            self.0
                .extend_from_slice(&(inner.len() as u32).to_le_bytes());
            self.0.extend_from_slice(inner);
        }
        fn string(&mut self, text: &str) {
            self.varuint(text.len() as u64);
            self.0.push(1);
            self.0.extend_from_slice(text.as_bytes());
        }
    }

    fn block(kind: u8, version: u8, data: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.push(0);
        out.push(version);
        out.push(version);
        out.push(kind);
        out.extend_from_slice(data);
        out
    }

    fn header() -> Vec<u8> {
        let mut bytes = b"reMarkable .lines file, version=6".to_vec();
        bytes.resize(HEADER_LEN, b' ');
        bytes
    }

    fn item_prefix(w: &mut Writer, id: CrdtId) {
        w.id(
            1,
            CrdtId {
                part1: 0,
                part2: 11,
            },
        );
        w.id(2, id);
        w.id(3, CrdtId::default());
        w.id(4, CrdtId::default());
        w.u32(5, 0);
    }

    fn line_block() -> Vec<u8> {
        let mut points = Vec::new();
        for (x, y) in [(-100.0f32, 50.0f32), (100.0, 60.0)] {
            points.extend_from_slice(&x.to_le_bytes());
            points.extend_from_slice(&y.to_le_bytes());
            points.extend_from_slice(&3u16.to_le_bytes()); // speed
            points.extend_from_slice(&4u16.to_le_bytes()); // width
            points.push(9); // direction
            points.push(255); // pressure
        }
        let mut value = Writer(vec![ITEM_LINE]);
        value.u32(1, 18); // highlighter (firmware 3 id)
        value.u32(2, 3);
        value.f64(3, 2.0);
        value.f32(4, 0.0);
        value.sub(5, &points);
        value.id(6, CrdtId { part1: 1, part2: 7 });
        let mut w = Writer(Vec::new());
        item_prefix(&mut w, CrdtId { part1: 1, part2: 3 });
        w.sub(6, &value.0);
        block(BLOCK_LINE_ITEM, 2, &w.0)
    }

    fn glyph_block() -> Vec<u8> {
        let mut value = Writer(vec![ITEM_GLYPH_RANGE]);
        value.u32(2, 12);
        value.u32(3, 11);
        value.u32(4, 3);
        let mut text = Writer(Vec::new());
        text.string("CALIBRATION");
        value.sub(5, &text.0);
        let mut rects = Writer(Vec::new());
        rects.varuint(2);
        for (x, y, w, h) in [
            (-400.0f64, 300.0f64, 200.0f64, 30.0f64),
            (-200.0, 300.0, 50.0, 30.0),
        ] {
            for v in [x, y, w, h] {
                rects.0.extend_from_slice(&v.to_le_bytes());
            }
        }
        value.sub(6, &rects.0);
        let mut w = Writer(Vec::new());
        item_prefix(&mut w, CrdtId { part1: 1, part2: 5 });
        w.sub(6, &value.0);
        block(BLOCK_GLYPH_ITEM, 1, &w.0)
    }

    fn root_text_block() -> Vec<u8> {
        let mut item_a = Writer(Vec::new());
        {
            let mut inner = Writer(Vec::new());
            inner.id(
                2,
                CrdtId {
                    part1: 1,
                    part2: 20,
                },
            );
            inner.id(3, CrdtId::default());
            inner.id(4, CrdtId::default());
            inner.u32(5, 0);
            let mut payload = Writer(Vec::new());
            payload.string("typed ");
            inner.sub(6, &payload.0);
            item_a.sub(0, &inner.0);
        }
        let mut item_b = Writer(Vec::new());
        {
            let mut inner = Writer(Vec::new());
            inner.id(
                2,
                CrdtId {
                    part1: 1,
                    part2: 21,
                },
            );
            inner.id(
                3,
                CrdtId {
                    part1: 1,
                    part2: 20,
                },
            );
            inner.id(4, CrdtId::default());
            inner.u32(5, 0);
            let mut payload = Writer(Vec::new());
            payload.string("line one");
            inner.sub(6, &payload.0);
            item_b.sub(0, &inner.0);
        }
        // File order deliberately reversed: b before a. The CRDT order
        // (a, then b whose left is a) must win.
        let mut items = Writer(Vec::new());
        items.varuint(2);
        items.0.extend_from_slice(&item_b.0);
        items.0.extend_from_slice(&item_a.0);
        let mut seq = Writer(Vec::new());
        seq.sub(1, &items.0);
        let mut outer = Writer(Vec::new());
        outer.sub(1, &seq.0);
        let mut w = Writer(Vec::new());
        w.id(1, CrdtId { part1: 0, part2: 1 });
        w.sub(2, &outer.0);
        let mut pos = Writer(Vec::new());
        pos.0.extend_from_slice(&(-468.0f64).to_le_bytes());
        pos.0.extend_from_slice(&234.0f64.to_le_bytes());
        w.sub(3, &pos.0);
        w.f32(4, 936.0);
        block(BLOCK_ROOT_TEXT, 1, &w.0)
    }

    #[test]
    fn lines_glyphs_and_typed_text_come_out_of_a_synthetic_page() {
        let mut bytes = header();
        bytes.extend(block(0x0A, 1, &[1, 2, 3])); // page info: skipped
        bytes.extend(line_block());
        bytes.extend(glyph_block());
        bytes.extend(root_text_block());
        let scene = parse_rm(&bytes).unwrap();
        assert_eq!(scene.version, 6);
        assert_eq!(scene.skipped_blocks, vec![0x0A]);

        assert_eq!(scene.lines.len(), 1);
        let line = &scene.lines[0];
        assert_eq!(line.tool, Tool::Highlighter);
        assert_eq!(line.id, Some(CrdtId { part1: 1, part2: 3 }));
        assert_eq!(line.points.len(), 2);
        assert_eq!(line.points[1].x, 100.0);
        assert!((line.points[1].pressure - 1.0).abs() < 1e-6);
        let bounds = line.bounds().unwrap();
        assert_eq!((bounds.x, bounds.w), (-100.0, 200.0));

        assert_eq!(scene.glyph_ranges.len(), 1);
        let glyph = &scene.glyph_ranges[0];
        assert_eq!(glyph.text, "CALIBRATION");
        assert_eq!(glyph.rects.len(), 2);
        assert_eq!(glyph.bounds().unwrap().w, 250.0);

        let text = scene.root_text.as_ref().unwrap();
        assert_eq!(text.text(), "typed line one");
        assert_eq!((text.pos_x, text.pos_y, text.width), (-468.0, 234.0, 936.0));
        assert!(scene.warnings.is_empty(), "{:?}", scene.warnings);
    }

    #[test]
    fn a_tombstone_and_an_unknown_field_are_passed_over() {
        let mut w = Writer(Vec::new());
        item_prefix(&mut w, CrdtId { part1: 1, part2: 9 });
        // deleted: no value sub-block at all
        let mut bytes = header();
        bytes.extend(block(BLOCK_LINE_ITEM, 2, &w.0));
        // A line whose value carries an extra unknown field 9 before the end.
        let mut value = Writer(vec![ITEM_LINE]);
        value.u32(1, 2);
        value.u32(2, 0);
        value.f64(3, 1.0);
        value.sub(5, &[]);
        value.u32(9, 42);
        let mut w2 = Writer(Vec::new());
        item_prefix(
            &mut w2,
            CrdtId {
                part1: 1,
                part2: 10,
            },
        );
        w2.sub(6, &value.0);
        bytes.extend(block(BLOCK_LINE_ITEM, 2, &w2.0));
        let scene = parse_rm(&bytes).unwrap();
        assert_eq!(scene.lines.len(), 1, "the tombstone is not a line");
        assert_eq!(scene.lines[0].tool, Tool::Ballpoint);
        assert!(scene.lines[0].points.is_empty());
    }

    #[test]
    fn a_truncated_block_is_an_error_not_a_panic() {
        let mut bytes = header();
        bytes.extend_from_slice(&[200, 0, 0, 0, 0, 1, 1, BLOCK_LINE_ITEM, 1, 2]);
        assert!(parse_rm(&bytes).is_err());
    }
}
