//! Viewport state for multi-app presence awareness
//!
//! Extends the basic cursor position model to support 3D viewports
//! (implore) and document views (imprint, imbib) for cross-app
//! presence tracking.

use serde::{Deserialize, Serialize};

/// A user's viewport state within a collaborative resource.
///
/// This extends basic cursor tracking to support different application modes:
/// - Document editing (imprint): text cursor position
/// - PDF viewing (imbib): page and viewport position
/// - 2D/3D visualization (implore): camera state
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ViewportState {
    /// The mode/context of this viewport
    pub mode: ViewportMode,

    /// 3D camera state (for implore Box3D/ArtShader modes)
    pub camera_3d: Option<Camera3DState>,

    /// 2D cursor/viewport position
    pub cursor_2d: Option<Point2D>,

    /// Selection bounds (for visualization selection)
    pub selection_bounds: Option<BoundingBox3D>,

    /// Zoom level (for 2D views)
    pub zoom_level: Option<f32>,

    /// Visible page number (for document/PDF views)
    pub visible_page: Option<u32>,
}

impl ViewportState {
    /// Create an empty viewport state
    pub fn new(mode: ViewportMode) -> Self {
        Self {
            mode,
            camera_3d: None,
            cursor_2d: None,
            selection_bounds: None,
            zoom_level: None,
            visible_page: None,
        }
    }

    /// Create a viewport state for document editing
    pub fn document(cursor: Point2D, page: u32) -> Self {
        Self {
            mode: ViewportMode::Document,
            camera_3d: None,
            cursor_2d: Some(cursor),
            selection_bounds: None,
            zoom_level: None,
            visible_page: Some(page),
        }
    }

    /// Create a viewport state for PDF reference viewing
    pub fn reference(page: u32, viewport: Option<Point2D>) -> Self {
        Self {
            mode: ViewportMode::Reference,
            camera_3d: None,
            cursor_2d: viewport,
            selection_bounds: None,
            zoom_level: None,
            visible_page: Some(page),
        }
    }

    /// Create a viewport state for 2D science visualization
    pub fn science_2d(cursor: Point2D, zoom: f32) -> Self {
        Self {
            mode: ViewportMode::Science2D,
            camera_3d: None,
            cursor_2d: Some(cursor),
            selection_bounds: None,
            zoom_level: Some(zoom),
            visible_page: None,
        }
    }

    /// Create a viewport state for 3D box visualization
    pub fn box_3d(camera: Camera3DState) -> Self {
        Self {
            mode: ViewportMode::Box3D,
            camera_3d: Some(camera),
            cursor_2d: None,
            selection_bounds: None,
            zoom_level: None,
            visible_page: None,
        }
    }

    /// Create a viewport state for art shader mode
    pub fn art_shader(camera: Camera3DState) -> Self {
        Self {
            mode: ViewportMode::ArtShader,
            camera_3d: Some(camera),
            cursor_2d: None,
            selection_bounds: None,
            zoom_level: None,
            visible_page: None,
        }
    }

    /// Update the 3D camera state
    pub fn update_camera(&mut self, camera: Camera3DState) {
        self.camera_3d = Some(camera);
    }

    /// Update the 2D cursor position
    pub fn update_cursor(&mut self, cursor: Point2D) {
        self.cursor_2d = Some(cursor);
    }

    /// Update the selection bounds
    pub fn update_selection(&mut self, bounds: BoundingBox3D) {
        self.selection_bounds = Some(bounds);
    }

    /// Clear the selection
    pub fn clear_selection(&mut self) {
        self.selection_bounds = None;
    }
}

impl Default for ViewportState {
    fn default() -> Self {
        Self::new(ViewportMode::Document)
    }
}

/// The mode/context of a viewport
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ViewportMode {
    /// imprint: text document editing
    Document,

    /// imbib: PDF reference viewing
    Reference,

    /// implore: 2D statistical plots
    Science2D,

    /// implore: 3D point cloud visualization
    Box3D,

    /// implore: art shader rendering
    ArtShader,
}

impl ViewportMode {
    /// Check if this mode is 3D (requires camera state)
    pub fn is_3d(&self) -> bool {
        matches!(self, ViewportMode::Box3D | ViewportMode::ArtShader)
    }

    /// Check if this mode is document-based
    pub fn is_document(&self) -> bool {
        matches!(self, ViewportMode::Document | ViewportMode::Reference)
    }

    /// Check if this mode is visualization
    pub fn is_visualization(&self) -> bool {
        matches!(
            self,
            ViewportMode::Science2D | ViewportMode::Box3D | ViewportMode::ArtShader
        )
    }

    /// Get the application this mode belongs to
    pub fn app(&self) -> &'static str {
        match self {
            ViewportMode::Document => "imprint",
            ViewportMode::Reference => "imbib",
            ViewportMode::Science2D | ViewportMode::Box3D | ViewportMode::ArtShader => "implore",
        }
    }
}

impl std::fmt::Display for ViewportMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ViewportMode::Document => write!(f, "Document"),
            ViewportMode::Reference => write!(f, "Reference"),
            ViewportMode::Science2D => write!(f, "Science 2D"),
            ViewportMode::Box3D => write!(f, "Box 3D"),
            ViewportMode::ArtShader => write!(f, "Art Shader"),
        }
    }
}

/// 3D camera state for visualization modes
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Camera3DState {
    /// Camera position in world coordinates
    pub position: [f32; 3],

    /// Point the camera is looking at
    pub target: [f32; 3],

    /// Camera up vector (typically [0, 1, 0] or [0, 0, 1])
    pub up: [f32; 3],

    /// Field of view in degrees (for perspective projection)
    pub fov: f32,

    /// Near clipping plane distance
    pub near: f32,

    /// Far clipping plane distance
    pub far: f32,
}

impl Camera3DState {
    /// Create a new camera state
    pub fn new(position: [f32; 3], target: [f32; 3]) -> Self {
        Self {
            position,
            target,
            up: [0.0, 1.0, 0.0],
            fov: 60.0,
            near: 0.1,
            far: 1000.0,
        }
    }

    /// Create a camera with Z-up convention (common in scientific visualization)
    pub fn with_z_up(position: [f32; 3], target: [f32; 3]) -> Self {
        Self {
            position,
            target,
            up: [0.0, 0.0, 1.0],
            fov: 60.0,
            near: 0.1,
            far: 1000.0,
        }
    }

    /// Set the field of view
    pub fn with_fov(mut self, fov: f32) -> Self {
        self.fov = fov;
        self
    }

    /// Set the clipping planes
    pub fn with_clip(mut self, near: f32, far: f32) -> Self {
        self.near = near;
        self.far = far;
        self
    }

    /// Set the up vector
    pub fn with_up(mut self, up: [f32; 3]) -> Self {
        self.up = up;
        self
    }

    /// Get the view direction (normalized)
    pub fn direction(&self) -> [f32; 3] {
        let dx = self.target[0] - self.position[0];
        let dy = self.target[1] - self.position[1];
        let dz = self.target[2] - self.position[2];
        let len = (dx * dx + dy * dy + dz * dz).sqrt();
        if len > 0.0 {
            [dx / len, dy / len, dz / len]
        } else {
            [0.0, 0.0, -1.0]
        }
    }

    /// Get the distance from camera to target
    pub fn distance(&self) -> f32 {
        let dx = self.target[0] - self.position[0];
        let dy = self.target[1] - self.position[1];
        let dz = self.target[2] - self.position[2];
        (dx * dx + dy * dy + dz * dz).sqrt()
    }

    /// Check if another camera is looking at approximately the same thing
    pub fn is_similar(&self, other: &Camera3DState, tolerance: f32) -> bool {
        let pos_diff = (self.position[0] - other.position[0]).abs()
            + (self.position[1] - other.position[1]).abs()
            + (self.position[2] - other.position[2]).abs();
        let target_diff = (self.target[0] - other.target[0]).abs()
            + (self.target[1] - other.target[1]).abs()
            + (self.target[2] - other.target[2]).abs();

        pos_diff < tolerance && target_diff < tolerance
    }
}

impl Default for Camera3DState {
    fn default() -> Self {
        Self::new([0.0, 0.0, 10.0], [0.0, 0.0, 0.0])
    }
}

/// A 2D point for cursor positions and viewport tracking
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Point2D {
    pub x: f64,
    pub y: f64,
}

impl Point2D {
    pub fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    pub fn origin() -> Self {
        Self { x: 0.0, y: 0.0 }
    }

    /// Distance to another point
    pub fn distance(&self, other: &Point2D) -> f64 {
        ((self.x - other.x).powi(2) + (self.y - other.y).powi(2)).sqrt()
    }
}

impl Default for Point2D {
    fn default() -> Self {
        Self::origin()
    }
}

/// A 3D axis-aligned bounding box for selection tracking
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct BoundingBox3D {
    pub min: [f64; 3],
    pub max: [f64; 3],
}

impl BoundingBox3D {
    /// Create a bounding box from min and max corners
    pub fn new(min: [f64; 3], max: [f64; 3]) -> Self {
        Self { min, max }
    }

    /// Create a bounding box centered at a point with given extents
    pub fn centered(center: [f64; 3], half_extents: [f64; 3]) -> Self {
        Self {
            min: [
                center[0] - half_extents[0],
                center[1] - half_extents[1],
                center[2] - half_extents[2],
            ],
            max: [
                center[0] + half_extents[0],
                center[1] + half_extents[1],
                center[2] + half_extents[2],
            ],
        }
    }

    /// Get the center of the bounding box
    pub fn center(&self) -> [f64; 3] {
        [
            (self.min[0] + self.max[0]) / 2.0,
            (self.min[1] + self.max[1]) / 2.0,
            (self.min[2] + self.max[2]) / 2.0,
        ]
    }

    /// Get the size (extents) of the bounding box
    pub fn size(&self) -> [f64; 3] {
        [
            self.max[0] - self.min[0],
            self.max[1] - self.min[1],
            self.max[2] - self.min[2],
        ]
    }

    /// Get the volume of the bounding box
    pub fn volume(&self) -> f64 {
        let s = self.size();
        s[0] * s[1] * s[2]
    }

    /// Check if a point is inside the bounding box
    pub fn contains(&self, point: &[f64; 3]) -> bool {
        point[0] >= self.min[0]
            && point[0] <= self.max[0]
            && point[1] >= self.min[1]
            && point[1] <= self.max[1]
            && point[2] >= self.min[2]
            && point[2] <= self.max[2]
    }

    /// Check if this bounding box overlaps with another
    pub fn overlaps(&self, other: &BoundingBox3D) -> bool {
        self.min[0] <= other.max[0]
            && self.max[0] >= other.min[0]
            && self.min[1] <= other.max[1]
            && self.max[1] >= other.min[1]
            && self.min[2] <= other.max[2]
            && self.max[2] >= other.min[2]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_viewport_mode_properties() {
        assert!(ViewportMode::Box3D.is_3d());
        assert!(ViewportMode::ArtShader.is_3d());
        assert!(!ViewportMode::Science2D.is_3d());

        assert!(ViewportMode::Document.is_document());
        assert!(ViewportMode::Reference.is_document());
        assert!(!ViewportMode::Box3D.is_document());

        assert!(ViewportMode::Science2D.is_visualization());
        assert!(ViewportMode::Box3D.is_visualization());
        assert!(!ViewportMode::Document.is_visualization());
    }

    #[test]
    fn test_viewport_mode_apps() {
        assert_eq!(ViewportMode::Document.app(), "imprint");
        assert_eq!(ViewportMode::Reference.app(), "imbib");
        assert_eq!(ViewportMode::Box3D.app(), "implore");
    }

    #[test]
    fn test_camera_3d_creation() {
        let camera = Camera3DState::new([0.0, 5.0, 10.0], [0.0, 0.0, 0.0]).with_fov(45.0);

        assert_eq!(camera.fov, 45.0);
        assert!((camera.distance() - 11.18).abs() < 0.1);
    }

    #[test]
    fn test_camera_3d_direction() {
        let camera = Camera3DState::new([0.0, 0.0, 10.0], [0.0, 0.0, 0.0]);
        let dir = camera.direction();

        assert!((dir[0]).abs() < 0.001);
        assert!((dir[1]).abs() < 0.001);
        assert!((dir[2] + 1.0).abs() < 0.001);
    }

    #[test]
    fn test_camera_3d_similarity() {
        let cam1 = Camera3DState::new([0.0, 0.0, 10.0], [0.0, 0.0, 0.0]);
        let cam2 = Camera3DState::new([0.1, 0.0, 10.0], [0.0, 0.0, 0.0]);
        let cam3 = Camera3DState::new([5.0, 5.0, 10.0], [0.0, 0.0, 0.0]);

        assert!(cam1.is_similar(&cam2, 0.5));
        assert!(!cam1.is_similar(&cam3, 0.5));
    }

    #[test]
    fn test_point_2d() {
        let p1 = Point2D::new(0.0, 0.0);
        let p2 = Point2D::new(3.0, 4.0);

        assert!((p1.distance(&p2) - 5.0).abs() < 0.001);
    }

    #[test]
    fn test_bounding_box_3d() {
        let bbox = BoundingBox3D::new([0.0, 0.0, 0.0], [10.0, 10.0, 10.0]);

        assert_eq!(bbox.center(), [5.0, 5.0, 5.0]);
        assert_eq!(bbox.size(), [10.0, 10.0, 10.0]);
        assert_eq!(bbox.volume(), 1000.0);

        assert!(bbox.contains(&[5.0, 5.0, 5.0]));
        assert!(!bbox.contains(&[11.0, 5.0, 5.0]));
    }

    #[test]
    fn test_bounding_box_3d_centered() {
        let bbox = BoundingBox3D::centered([0.0, 0.0, 0.0], [5.0, 5.0, 5.0]);

        assert_eq!(bbox.min, [-5.0, -5.0, -5.0]);
        assert_eq!(bbox.max, [5.0, 5.0, 5.0]);
    }

    #[test]
    fn test_bounding_box_3d_overlap() {
        let bbox1 = BoundingBox3D::new([0.0, 0.0, 0.0], [10.0, 10.0, 10.0]);
        let bbox2 = BoundingBox3D::new([5.0, 5.0, 5.0], [15.0, 15.0, 15.0]);
        let bbox3 = BoundingBox3D::new([20.0, 20.0, 20.0], [30.0, 30.0, 30.0]);

        assert!(bbox1.overlaps(&bbox2));
        assert!(!bbox1.overlaps(&bbox3));
    }

    #[test]
    fn test_viewport_state_document() {
        let state = ViewportState::document(Point2D::new(100.0, 200.0), 5);

        assert_eq!(state.mode, ViewportMode::Document);
        assert_eq!(state.visible_page, Some(5));
        assert!(state.cursor_2d.is_some());
    }

    #[test]
    fn test_viewport_state_3d() {
        let camera = Camera3DState::new([0.0, 0.0, 10.0], [0.0, 0.0, 0.0]);
        let state = ViewportState::box_3d(camera);

        assert_eq!(state.mode, ViewportMode::Box3D);
        assert!(state.camera_3d.is_some());
        assert!(state.cursor_2d.is_none());
    }
}
