//! Rendering configuration and primitives
//!
//! Defines render modes, wireframe box, and GPU-ready data structures
//! for scientific visualization.

use serde::{Deserialize, Serialize};

use crate::camera::Camera;
use crate::colormap::ColormapConfig;

/// Rendering mode for visualization
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum RenderMode {
    /// 2D statistical plots with axes, colormaps, and ECDF marginals
    Science2D,
    /// 3D point cloud viewer with perspective camera
    Box3D,
    /// Custom shader rendering for artistic visualizations
    ArtShader,
    /// 1D histogram with KDE overlay and statistics
    Histogram1D,
}

impl RenderMode {
    /// Cycle to the next render mode (Tab key behavior)
    pub fn cycle(&self) -> Self {
        match self {
            RenderMode::Science2D => RenderMode::Box3D,
            RenderMode::Box3D => RenderMode::ArtShader,
            RenderMode::ArtShader => RenderMode::Histogram1D,
            RenderMode::Histogram1D => RenderMode::Science2D,
        }
    }

    /// Cycle to previous render mode (Shift+Tab)
    pub fn cycle_reverse(&self) -> Self {
        match self {
            RenderMode::Science2D => RenderMode::Histogram1D,
            RenderMode::Box3D => RenderMode::Science2D,
            RenderMode::ArtShader => RenderMode::Box3D,
            RenderMode::Histogram1D => RenderMode::ArtShader,
        }
    }

    /// Display name for the mode
    pub fn name(&self) -> &'static str {
        match self {
            RenderMode::Science2D => "Science 2D",
            RenderMode::Box3D => "Box 3D",
            RenderMode::ArtShader => "Art Shader",
            RenderMode::Histogram1D => "Histogram 1D",
        }
    }

    /// Short name for status bar
    pub fn short_name(&self) -> &'static str {
        match self {
            RenderMode::Science2D => "2D",
            RenderMode::Box3D => "3D",
            RenderMode::ArtShader => "Art",
            RenderMode::Histogram1D => "1D",
        }
    }
}

impl Default for RenderMode {
    fn default() -> Self {
        RenderMode::Science2D
    }
}

/// Configuration for Science2D mode
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Science2DConfig {
    /// X-axis field name
    pub x_field: String,
    /// Y-axis field name
    pub y_field: String,
    /// Color field name (optional, for colormap)
    pub color_field: Option<String>,
    /// Size field name (optional, for point sizing)
    pub size_field: Option<String>,
    /// Show X-axis marginal (ECDF)
    pub show_x_marginal: bool,
    /// Show Y-axis marginal (ECDF)
    pub show_y_marginal: bool,
    /// Show grid lines
    pub show_grid: bool,
    /// Use log scale for X
    pub log_x: bool,
    /// Use log scale for Y
    pub log_y: bool,
}

impl Default for Science2DConfig {
    fn default() -> Self {
        Self {
            x_field: "x".to_string(),
            y_field: "y".to_string(),
            color_field: None,
            size_field: None,
            show_x_marginal: true,
            show_y_marginal: true,
            show_grid: false,
            log_x: false,
            log_y: false,
        }
    }
}

/// Configuration for Box3D mode
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Box3DConfig {
    /// X-axis field name
    pub x_field: String,
    /// Y-axis field name
    pub y_field: String,
    /// Z-axis field name
    pub z_field: String,
    /// Color field name (optional)
    pub color_field: Option<String>,
    /// Size field name (optional)
    pub size_field: Option<String>,
    /// Show wireframe box
    pub show_box: bool,
    /// Show axis labels
    pub show_labels: bool,
    /// Enable depth cueing (fog)
    pub depth_cueing: bool,
    /// Depth cueing strength (0.0 = none, 1.0 = full)
    pub depth_cueing_strength: f32,
}

impl Default for Box3DConfig {
    fn default() -> Self {
        Self {
            x_field: "x".to_string(),
            y_field: "y".to_string(),
            z_field: "z".to_string(),
            color_field: None,
            size_field: None,
            show_box: true,
            show_labels: true,
            depth_cueing: true,
            depth_cueing_strength: 0.5,
        }
    }
}

/// Configuration for ArtShader mode
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ArtShaderConfig {
    /// Shader preset name
    pub preset: String,
    /// Custom shader source (if not using preset)
    pub custom_shader: Option<String>,
    /// Animation enabled
    pub animate: bool,
    /// Animation speed multiplier
    pub animation_speed: f32,
    /// Post-processing: bloom enabled
    pub bloom: bool,
    /// Post-processing: bloom intensity
    pub bloom_intensity: f32,
}

impl Default for ArtShaderConfig {
    fn default() -> Self {
        Self {
            preset: "nebula".to_string(),
            custom_shader: None,
            animate: true,
            animation_speed: 1.0,
            bloom: true,
            bloom_intensity: 0.3,
        }
    }
}

/// Configuration for Histogram1D mode
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Histogram1DConfig {
    /// Field to histogram
    pub field: String,
    /// Number of bins (None = auto via Freedman-Diaconis rule)
    pub num_bins: Option<u32>,
    /// Log scale for X axis (field values)
    pub log_scale_x: bool,
    /// Log scale for Y axis (counts)
    pub log_scale_y: bool,
    /// Show KDE overlay
    pub show_kde: bool,
    /// KDE bandwidth (None = auto Scott's rule)
    pub kde_bandwidth: Option<f64>,
    /// Show statistics panel (mean, median, std dev, percentiles)
    pub show_statistics: bool,
    /// Secondary field for color-coding bars
    pub color_field: Option<String>,
    /// Bin edge mode
    pub bin_edges: BinEdgeMode,
}

/// Bin edge computation mode
#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum BinEdgeMode {
    /// Evenly spaced bins
    Linear,
    /// Log-spaced bins (for log-scale data)
    Logarithmic,
    /// Custom bin edges
    Custom(Vec<f64>),
}

impl Default for BinEdgeMode {
    fn default() -> Self {
        BinEdgeMode::Linear
    }
}

impl Default for Histogram1DConfig {
    fn default() -> Self {
        Self {
            field: "x".to_string(),
            num_bins: None,
            log_scale_x: false,
            log_scale_y: false,
            show_kde: true,
            kde_bandwidth: None,
            show_statistics: true,
            color_field: None,
            bin_edges: BinEdgeMode::default(),
        }
    }
}

/// Complete render configuration
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RenderConfig {
    /// Current render mode
    pub mode: RenderMode,
    /// Science 2D settings
    pub science_2d: Science2DConfig,
    /// Box 3D settings
    pub box_3d: Box3DConfig,
    /// Art shader settings
    pub art_shader: ArtShaderConfig,
    /// Histogram 1D settings
    pub histogram_1d: Histogram1DConfig,
    /// Colormap configuration
    pub colormap: ColormapConfig,
    /// Base point size
    pub point_size: f32,
    /// Point size range (min, max)
    pub point_size_range: (f32, f32),
    /// Background color [r, g, b, a]
    pub background_color: [f32; 4],
    /// Selection highlight color
    pub selection_color: [f32; 4],
}

impl Default for RenderConfig {
    fn default() -> Self {
        Self {
            mode: RenderMode::default(),
            science_2d: Science2DConfig::default(),
            box_3d: Box3DConfig::default(),
            art_shader: ArtShaderConfig::default(),
            histogram_1d: Histogram1DConfig::default(),
            colormap: ColormapConfig::default(),
            point_size: 4.0,
            point_size_range: (1.0, 20.0),
            background_color: [0.05, 0.05, 0.08, 1.0], // Dark blue-gray
            selection_color: [1.0, 0.8, 0.0, 1.0],     // Gold
        }
    }
}

/// 3D wireframe box for bounding visualization
#[derive(Clone, Debug)]
pub struct WireframeBox {
    /// Minimum corner
    pub min: [f32; 3],
    /// Maximum corner
    pub max: [f32; 3],
    /// Line color
    pub color: [f32; 4],
    /// Line width
    pub line_width: f32,
}

impl WireframeBox {
    /// Create a unit box centered at origin
    pub fn unit() -> Self {
        Self {
            min: [-0.5, -0.5, -0.5],
            max: [0.5, 0.5, 0.5],
            color: [0.5, 0.5, 0.5, 1.0],
            line_width: 1.0,
        }
    }

    /// Create a box from bounds
    pub fn from_bounds(min: [f32; 3], max: [f32; 3]) -> Self {
        Self {
            min,
            max,
            color: [0.5, 0.5, 0.5, 1.0],
            line_width: 1.0,
        }
    }

    /// Get the 8 vertices of the box
    pub fn vertices(&self) -> [[f32; 3]; 8] {
        let [x0, y0, z0] = self.min;
        let [x1, y1, z1] = self.max;

        [
            [x0, y0, z0], // 0: front-bottom-left
            [x1, y0, z0], // 1: front-bottom-right
            [x1, y1, z0], // 2: front-top-right
            [x0, y1, z0], // 3: front-top-left
            [x0, y0, z1], // 4: back-bottom-left
            [x1, y0, z1], // 5: back-bottom-right
            [x1, y1, z1], // 6: back-top-right
            [x0, y1, z1], // 7: back-top-left
        ]
    }

    /// Get the 12 edges as vertex index pairs
    pub fn edges(&self) -> [(usize, usize); 12] {
        [
            // Front face
            (0, 1),
            (1, 2),
            (2, 3),
            (3, 0),
            // Back face
            (4, 5),
            (5, 6),
            (6, 7),
            (7, 4),
            // Connecting edges
            (0, 4),
            (1, 5),
            (2, 6),
            (3, 7),
        ]
    }

    /// Generate line vertices for rendering (24 vertices = 12 edges × 2)
    pub fn line_vertices(&self) -> Vec<[f32; 3]> {
        let verts = self.vertices();
        let edges = self.edges();

        let mut lines = Vec::with_capacity(24);
        for (i, j) in edges {
            lines.push(verts[i]);
            lines.push(verts[j]);
        }
        lines
    }

    /// Get center of the box
    pub fn center(&self) -> [f32; 3] {
        [
            (self.min[0] + self.max[0]) / 2.0,
            (self.min[1] + self.max[1]) / 2.0,
            (self.min[2] + self.max[2]) / 2.0,
        ]
    }

    /// Get size of the box
    pub fn size(&self) -> [f32; 3] {
        [
            self.max[0] - self.min[0],
            self.max[1] - self.min[1],
            self.max[2] - self.min[2],
        ]
    }

    /// Get maximum dimension
    pub fn max_dimension(&self) -> f32 {
        let size = self.size();
        size[0].max(size[1]).max(size[2])
    }
}

impl Default for WireframeBox {
    fn default() -> Self {
        Self::unit()
    }
}

/// GPU uniforms for point rendering
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PointUniforms {
    /// Model-view-projection matrix
    pub mvp: [[f32; 4]; 4],
    /// Model-view matrix (for depth calculations)
    pub mv: [[f32; 4]; 4],
    /// Point size multiplier
    pub point_size_multiplier: f32,
    /// Animation time
    pub time: f32,
    /// Viewport size [width, height]
    pub viewport_size: [f32; 2],
    /// Depth cueing near distance
    pub depth_near: f32,
    /// Depth cueing far distance
    pub depth_far: f32,
    /// Depth cueing strength
    pub depth_strength: f32,
    /// Padding for alignment
    pub _padding: f32,
}

impl PointUniforms {
    /// Create uniforms from camera and config
    pub fn from_camera(camera: &Camera, config: &RenderConfig, viewport: [f32; 2]) -> Self {
        let view = camera.view_matrix();
        let proj = camera.projection_matrix();
        let mvp = mat4_multiply(proj, view);

        Self {
            mvp,
            mv: view,
            point_size_multiplier: config.point_size,
            time: 0.0,
            viewport_size: viewport,
            depth_near: camera.near,
            depth_far: camera.far,
            depth_strength: config.box_3d.depth_cueing_strength,
            _padding: 0.0,
        }
    }

    /// Update time for animation
    pub fn with_time(mut self, time: f32) -> Self {
        self.time = time;
        self
    }
}

impl Default for PointUniforms {
    fn default() -> Self {
        Self {
            mvp: identity_matrix(),
            mv: identity_matrix(),
            point_size_multiplier: 4.0,
            time: 0.0,
            viewport_size: [800.0, 600.0],
            depth_near: 0.1,
            depth_far: 100.0,
            depth_strength: 0.5,
            _padding: 0.0,
        }
    }
}

/// GPU uniforms for selection highlight
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SelectionUniforms {
    /// Highlight color
    pub highlight_color: [f32; 4],
    /// Pulse animation phase
    pub pulse_phase: f32,
    /// Padding for alignment
    pub _padding: [f32; 3],
}

impl Default for SelectionUniforms {
    fn default() -> Self {
        Self {
            highlight_color: [1.0, 0.8, 0.0, 1.0],
            pulse_phase: 0.0,
            _padding: [0.0; 3],
        }
    }
}

/// Axis label position for 3D
#[derive(Clone, Debug)]
pub struct AxisLabel3D {
    /// Label text
    pub text: String,
    /// World position
    pub position: [f32; 3],
    /// Axis (X, Y, or Z)
    pub axis: Axis3D,
    /// Is this the axis title?
    pub is_title: bool,
}

/// 3D axis identifier
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Axis3D {
    X,
    Y,
    Z,
}

/// Generate axis labels for 3D box
pub fn generate_3d_labels(bounds: &WireframeBox, divisions: usize) -> Vec<AxisLabel3D> {
    let mut labels = Vec::new();
    let [x0, y0, z0] = bounds.min;
    let [x1, y1, z1] = bounds.max;

    // X axis labels along bottom-front edge
    for i in 0..=divisions {
        let t = i as f32 / divisions as f32;
        let x = x0 + t * (x1 - x0);
        labels.push(AxisLabel3D {
            text: format!("{:.1}", x),
            position: [x, y0, z0],
            axis: Axis3D::X,
            is_title: false,
        });
    }

    // Y axis labels along left-front edge
    for i in 0..=divisions {
        let t = i as f32 / divisions as f32;
        let y = y0 + t * (y1 - y0);
        labels.push(AxisLabel3D {
            text: format!("{:.1}", y),
            position: [x0, y, z0],
            axis: Axis3D::Y,
            is_title: false,
        });
    }

    // Z axis labels along bottom-left edge
    for i in 0..=divisions {
        let t = i as f32 / divisions as f32;
        let z = z0 + t * (z1 - z0);
        labels.push(AxisLabel3D {
            text: format!("{:.1}", z),
            position: [x0, y0, z],
            axis: Axis3D::Z,
            is_title: false,
        });
    }

    // Axis titles
    labels.push(AxisLabel3D {
        text: "X".to_string(),
        position: [(x0 + x1) / 2.0, y0 - (y1 - y0) * 0.1, z0],
        axis: Axis3D::X,
        is_title: true,
    });

    labels.push(AxisLabel3D {
        text: "Y".to_string(),
        position: [x0 - (x1 - x0) * 0.1, (y0 + y1) / 2.0, z0],
        axis: Axis3D::Y,
        is_title: true,
    });

    labels.push(AxisLabel3D {
        text: "Z".to_string(),
        position: [x0, y0 - (y1 - y0) * 0.1, (z0 + z1) / 2.0],
        axis: Axis3D::Z,
        is_title: true,
    });

    labels
}

// MARK: - Matrix utilities

fn identity_matrix() -> [[f32; 4]; 4] {
    [
        [1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [0.0, 0.0, 0.0, 1.0],
    ]
}

fn mat4_multiply(a: [[f32; 4]; 4], b: [[f32; 4]; 4]) -> [[f32; 4]; 4] {
    let mut result = [[0.0; 4]; 4];

    for i in 0..4 {
        for j in 0..4 {
            for k in 0..4 {
                result[i][j] += a[k][j] * b[i][k];
            }
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_render_mode_cycle() {
        let mode = RenderMode::Science2D;
        assert_eq!(mode.cycle(), RenderMode::Box3D);
        assert_eq!(mode.cycle().cycle(), RenderMode::ArtShader);
        assert_eq!(mode.cycle().cycle().cycle(), RenderMode::Histogram1D);
        assert_eq!(mode.cycle().cycle().cycle().cycle(), RenderMode::Science2D);
    }

    #[test]
    fn test_render_mode_cycle_reverse() {
        let mode = RenderMode::Science2D;
        assert_eq!(mode.cycle_reverse(), RenderMode::Histogram1D);
        assert_eq!(mode.cycle_reverse().cycle_reverse(), RenderMode::ArtShader);
        assert_eq!(
            mode.cycle_reverse().cycle_reverse().cycle_reverse(),
            RenderMode::Box3D
        );
    }

    #[test]
    fn test_histogram_1d_config_default() {
        let config = Histogram1DConfig::default();
        assert_eq!(config.field, "x");
        assert!(config.num_bins.is_none());
        assert!(config.show_kde);
        assert!(config.show_statistics);
    }

    #[test]
    fn test_wireframe_box_vertices() {
        let bbox = WireframeBox::unit();
        let verts = bbox.vertices();
        assert_eq!(verts.len(), 8);

        // Check that all vertices are within bounds
        for v in &verts {
            assert!(v[0] >= -0.5 && v[0] <= 0.5);
            assert!(v[1] >= -0.5 && v[1] <= 0.5);
            assert!(v[2] >= -0.5 && v[2] <= 0.5);
        }
    }

    #[test]
    fn test_wireframe_box_edges() {
        let bbox = WireframeBox::unit();
        let edges = bbox.edges();
        assert_eq!(edges.len(), 12);

        // All edge indices should be valid
        for (i, j) in &edges {
            assert!(*i < 8);
            assert!(*j < 8);
        }
    }

    #[test]
    fn test_wireframe_box_line_vertices() {
        let bbox = WireframeBox::unit();
        let lines = bbox.line_vertices();
        assert_eq!(lines.len(), 24); // 12 edges × 2 vertices
    }

    #[test]
    fn test_wireframe_box_center() {
        let bbox = WireframeBox::from_bounds([0.0, 0.0, 0.0], [10.0, 20.0, 30.0]);
        let center = bbox.center();
        assert!((center[0] - 5.0).abs() < 0.001);
        assert!((center[1] - 10.0).abs() < 0.001);
        assert!((center[2] - 15.0).abs() < 0.001);
    }

    #[test]
    fn test_wireframe_box_max_dimension() {
        let bbox = WireframeBox::from_bounds([0.0, 0.0, 0.0], [10.0, 20.0, 30.0]);
        assert!((bbox.max_dimension() - 30.0).abs() < 0.001);
    }

    #[test]
    fn test_generate_3d_labels() {
        let bbox = WireframeBox::unit();
        let labels = generate_3d_labels(&bbox, 2);

        // Should have labels for each axis (3 values each) + 3 titles
        assert!(labels.len() >= 12);

        // Check that we have titles
        let titles: Vec<_> = labels.iter().filter(|l| l.is_title).collect();
        assert_eq!(titles.len(), 3);
    }

    #[test]
    fn test_point_uniforms_default() {
        let uniforms = PointUniforms::default();
        assert_eq!(uniforms.point_size_multiplier, 4.0);
        assert_eq!(uniforms.viewport_size, [800.0, 600.0]);
    }

    #[test]
    fn test_selection_uniforms() {
        let uniforms = SelectionUniforms::default();
        assert_eq!(uniforms.highlight_color[3], 1.0); // Alpha should be 1
    }
}
