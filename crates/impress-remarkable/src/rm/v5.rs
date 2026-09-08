//! Firmware-2 `.lines` files (versions 3 and 5): a flat layout of layers,
//! strokes and 24-byte points, little-endian.

use super::{Line, Point, RmScene, Tool};
use crate::error::{Error, Result};

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.pos + n > self.bytes.len() {
            return Err(Error::Format {
                path: "<rm v5>".into(),
                detail: format!("truncated at byte {} (wanted {n} more)", self.pos),
            });
        }
        let slice = &self.bytes[self.pos..self.pos + n];
        self.pos += n;
        Ok(slice)
    }

    fn i32(&mut self) -> Result<i32> {
        Ok(i32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn f32(&mut self) -> Result<f32> {
        Ok(f32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
}

pub(super) fn parse(version: u8, body: &[u8]) -> Result<RmScene> {
    let mut reader = Reader {
        bytes: body,
        pos: 0,
    };
    let mut scene = RmScene {
        version,
        ..Default::default()
    };
    let layer_count = reader.i32()?;
    if !(0..=64).contains(&layer_count) {
        return Err(Error::Format {
            path: "<rm v5>".into(),
            detail: format!("implausible layer count {layer_count}"),
        });
    }
    scene.layer_count = layer_count as usize;
    for layer in 0..layer_count as usize {
        let stroke_count = reader.i32()?;
        if stroke_count < 0 {
            return Err(Error::Format {
                path: "<rm v5>".into(),
                detail: format!("negative stroke count in layer {layer}"),
            });
        }
        for _ in 0..stroke_count {
            let pen = reader.i32()?;
            let color = reader.i32()?;
            let _unknown = reader.i32()?;
            let width = reader.f32()?;
            if version >= 5 {
                let _unknown2 = reader.i32()?;
            }
            let point_count = reader.i32()?;
            if point_count < 0 {
                return Err(Error::Format {
                    path: "<rm v5>".into(),
                    detail: "negative point count".into(),
                });
            }
            let mut points = Vec::with_capacity(point_count as usize);
            for _ in 0..point_count {
                points.push(Point {
                    x: reader.f32()?,
                    y: reader.f32()?,
                    speed: reader.f32()?,
                    direction: reader.f32()?,
                    width: reader.f32()?,
                    pressure: reader.f32()?,
                });
            }
            scene.lines.push(Line {
                id: None,
                layer,
                tool: Tool::from_id(pen.max(0) as u32),
                color: color.max(0) as u32,
                rgba: None,
                thickness_scale: f64::from(width),
                points,
            });
        }
    }
    if reader.pos != body.len() {
        scene.warnings.push(format!(
            "{} trailing byte(s) after the last layer",
            body.len() - reader.pos
        ));
    }
    Ok(scene)
}

#[cfg(test)]
mod tests {
    use super::super::{parse_rm, Tool, HEADER_LEN};

    fn header(version: u8) -> Vec<u8> {
        let mut bytes = format!("reMarkable .lines file, version={version}").into_bytes();
        bytes.resize(HEADER_LEN, b' ');
        bytes
    }

    fn le(v: i32) -> [u8; 4] {
        v.to_le_bytes()
    }

    #[test]
    fn a_synthetic_version_5_page_with_one_stroke() {
        let mut bytes = header(5);
        bytes.extend_from_slice(&le(1)); // layers
        bytes.extend_from_slice(&le(1)); // strokes
        bytes.extend_from_slice(&le(18)); // pen: highlighter
        bytes.extend_from_slice(&le(0)); // color
        bytes.extend_from_slice(&le(0)); // unknown
        bytes.extend_from_slice(&2.0f32.to_le_bytes()); // width
        bytes.extend_from_slice(&le(0)); // unknown2 (v5)
        bytes.extend_from_slice(&le(2)); // points
        for (x, y) in [(10.0f32, 20.0f32), (110.0, 24.0)] {
            for value in [x, y, 0.0, 0.0, 2.0, 1.0] {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
        let scene = parse_rm(&bytes).unwrap();
        assert_eq!(scene.lines.len(), 1);
        assert_eq!(scene.lines[0].tool, Tool::Highlighter);
        let bounds = scene.lines[0].bounds().unwrap();
        assert_eq!(
            (bounds.x, bounds.y, bounds.w, bounds.h),
            (10.0, 20.0, 100.0, 4.0)
        );
        assert!(scene.warnings.is_empty());
    }

    #[test]
    fn a_truncated_page_is_an_error_not_a_panic() {
        let mut bytes = header(5);
        bytes.extend_from_slice(&le(1));
        bytes.extend_from_slice(&le(1));
        bytes.extend_from_slice(&le(2));
        assert!(parse_rm(&bytes).is_err());
    }
}
