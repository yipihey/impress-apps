//! Annotation type definitions

use chrono::Utc;
use serde::{Deserialize, Serialize};

/// A rectangle on a PDF page (in PDF coordinates)
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl Rect {
    pub fn new(x: f32, y: f32, width: f32, height: f32) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    pub fn contains_point(&self, x: f32, y: f32) -> bool {
        x >= self.x && x <= self.x + self.width && y >= self.y && y <= self.y + self.height
    }

    pub fn intersects(&self, other: &Rect) -> bool {
        self.x < other.x + other.width
            && self.x + self.width > other.x
            && self.y < other.y + other.height
            && self.y + self.height > other.y
    }
}

/// Point on a page
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Point {
    pub x: f32,
    pub y: f32,
}

/// Color in RGBA format
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AnnotationColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl AnnotationColor {
    pub fn yellow() -> Self {
        Self {
            r: 255,
            g: 255,
            b: 0,
            a: 128,
        }
    }

    pub fn green() -> Self {
        Self {
            r: 0,
            g: 255,
            b: 0,
            a: 128,
        }
    }

    pub fn red() -> Self {
        Self {
            r: 255,
            g: 0,
            b: 0,
            a: 128,
        }
    }

    pub fn blue() -> Self {
        Self {
            r: 0,
            g: 0,
            b: 255,
            a: 128,
        }
    }

    pub fn to_hex(&self) -> String {
        format!("#{:02x}{:02x}{:02x}{:02x}", self.r, self.g, self.b, self.a)
    }

    pub fn from_hex(hex: &str) -> Option<Self> {
        let hex = hex.trim_start_matches('#');
        if hex.len() == 6 {
            let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
            let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
            let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
            Some(Self { r, g, b, a: 255 })
        } else if hex.len() == 8 {
            let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
            let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
            let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
            let a = u8::from_str_radix(&hex[6..8], 16).ok()?;
            Some(Self { r, g, b, a })
        } else {
            None
        }
    }
}

/// Annotation type
#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum AnnotationType {
    Highlight,
    Underline,
    StrikeOut,
    Squiggly,
    Note,
    FreeText,
    Drawing,
    Link,
}

/// A single annotation on a PDF page
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct Annotation {
    pub id: String,
    pub publication_id: String,
    pub page_number: u32,
    pub annotation_type: AnnotationType,
    pub rects: Vec<Rect>, // Multiple rects for multi-line highlights
    pub color: AnnotationColor,
    pub content: Option<String>,       // Note text or link URL
    pub selected_text: Option<String>, // Text that was highlighted
    pub created_at: String,
    pub modified_at: String,
    pub author: Option<String>,
}

impl Annotation {
    pub fn new_highlight(
        publication_id: String,
        page_number: u32,
        rects: Vec<Rect>,
        selected_text: Option<String>,
    ) -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            publication_id,
            page_number,
            annotation_type: AnnotationType::Highlight,
            rects,
            color: AnnotationColor::yellow(),
            content: None,
            selected_text,
            created_at: now.clone(),
            modified_at: now,
            author: None,
        }
    }

    pub fn new_note(
        publication_id: String,
        page_number: u32,
        position: Rect,
        content: String,
    ) -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            publication_id,
            page_number,
            annotation_type: AnnotationType::Note,
            rects: vec![position],
            color: AnnotationColor::yellow(),
            content: Some(content),
            selected_text: None,
            created_at: now.clone(),
            modified_at: now,
            author: None,
        }
    }

    pub fn new_freetext(
        publication_id: String,
        page_number: u32,
        rect: Rect,
        text: String,
    ) -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            publication_id,
            page_number,
            annotation_type: AnnotationType::FreeText,
            rects: vec![rect],
            color: AnnotationColor {
                r: 0,
                g: 0,
                b: 0,
                a: 255,
            },
            content: Some(text),
            selected_text: None,
            created_at: now.clone(),
            modified_at: now,
            author: None,
        }
    }

    pub fn update_content(&mut self, content: String) {
        self.content = Some(content);
        self.modified_at = Utc::now().to_rfc3339();
    }

    pub fn update_color(&mut self, color: AnnotationColor) {
        self.color = color;
        self.modified_at = Utc::now().to_rfc3339();
    }
}

/// Drawing stroke for freehand annotations
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct DrawingStroke {
    pub points: Vec<Point>,
    pub color: AnnotationColor,
    pub width: f32,
}

/// Drawing annotation (multiple strokes)
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct DrawingAnnotation {
    pub id: String,
    pub publication_id: String,
    pub page_number: u32,
    pub strokes: Vec<DrawingStroke>,
    pub created_at: String,
    pub modified_at: String,
}

impl DrawingAnnotation {
    pub fn new(publication_id: String, page_number: u32) -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            publication_id,
            page_number,
            strokes: Vec::new(),
            created_at: now.clone(),
            modified_at: now,
        }
    }

    pub fn add_stroke(&mut self, stroke: DrawingStroke) {
        self.strokes.push(stroke);
        self.modified_at = Utc::now().to_rfc3339();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rect_contains() {
        let rect = Rect::new(10.0, 10.0, 100.0, 50.0);
        assert!(rect.contains_point(50.0, 30.0));
        assert!(!rect.contains_point(5.0, 30.0));
    }

    #[test]
    fn test_color_hex() {
        let color = AnnotationColor::yellow();
        let hex = color.to_hex();
        let parsed = AnnotationColor::from_hex(&hex).unwrap();
        assert_eq!(color, parsed);
    }

    #[test]
    fn test_rect_intersects() {
        let rect1 = Rect::new(0.0, 0.0, 100.0, 100.0);
        let rect2 = Rect::new(50.0, 50.0, 100.0, 100.0);
        let rect3 = Rect::new(200.0, 200.0, 100.0, 100.0);

        assert!(rect1.intersects(&rect2));
        assert!(!rect1.intersects(&rect3));
    }
}
