//! Abstract Syntax Tree for selection expressions
//!
//! This module defines the AST types used by the selection grammar parser.

use serde::{Deserialize, Serialize};

/// A selection expression
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum SelectionExpr {
    /// Logical AND of two expressions
    And(Box<SelectionExpr>, Box<SelectionExpr>),

    /// Logical OR of two expressions
    Or(Box<SelectionExpr>, Box<SelectionExpr>),

    /// Logical NOT of an expression
    Not(Box<SelectionExpr>),

    /// A comparison predicate
    Comparison(Comparison),

    /// A geometric primitive (sphere, box, etc.)
    Geometric(GeometricPrimitive),

    /// A statistical filter (zscore, percentile)
    Statistical(StatisticalFilter),

    /// Reference to a named register
    Register(String),

    /// All points (constant true)
    All,

    /// No points (constant false)
    None,
}

impl SelectionExpr {
    /// Create an AND expression
    pub fn and(left: SelectionExpr, right: SelectionExpr) -> Self {
        SelectionExpr::And(Box::new(left), Box::new(right))
    }

    /// Create an OR expression
    pub fn or(left: SelectionExpr, right: SelectionExpr) -> Self {
        SelectionExpr::Or(Box::new(left), Box::new(right))
    }

    /// Create a NOT expression
    pub fn not(expr: SelectionExpr) -> Self {
        SelectionExpr::Not(Box::new(expr))
    }

    /// Check if this is an atomic expression (no operators)
    pub fn is_atomic(&self) -> bool {
        matches!(
            self,
            SelectionExpr::Comparison(_)
                | SelectionExpr::Geometric(_)
                | SelectionExpr::Statistical(_)
                | SelectionExpr::Register(_)
                | SelectionExpr::All
                | SelectionExpr::None
        )
    }
}

/// A comparison predicate
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Comparison {
    /// Left-hand side (usually a field name)
    pub lhs: Value,
    /// Comparison operator
    pub op: ComparisonOp,
    /// Right-hand side (usually a literal)
    pub rhs: Value,
}

impl Comparison {
    /// Create a new comparison
    pub fn new(lhs: Value, op: ComparisonOp, rhs: Value) -> Self {
        Self { lhs, op, rhs }
    }

    /// Create a field < value comparison
    pub fn field_lt(field: &str, value: f64) -> Self {
        Self::new(
            Value::Field(field.to_string()),
            ComparisonOp::Lt,
            Value::Number(value),
        )
    }

    /// Create a field <= value comparison
    pub fn field_le(field: &str, value: f64) -> Self {
        Self::new(
            Value::Field(field.to_string()),
            ComparisonOp::Le,
            Value::Number(value),
        )
    }

    /// Create a field > value comparison
    pub fn field_gt(field: &str, value: f64) -> Self {
        Self::new(
            Value::Field(field.to_string()),
            ComparisonOp::Gt,
            Value::Number(value),
        )
    }

    /// Create a field >= value comparison
    pub fn field_ge(field: &str, value: f64) -> Self {
        Self::new(
            Value::Field(field.to_string()),
            ComparisonOp::Ge,
            Value::Number(value),
        )
    }

    /// Create a field == value comparison
    pub fn field_eq(field: &str, value: f64) -> Self {
        Self::new(
            Value::Field(field.to_string()),
            ComparisonOp::Eq,
            Value::Number(value),
        )
    }
}

/// Comparison operators
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ComparisonOp {
    /// Less than (<)
    Lt,
    /// Less than or equal (<=)
    Le,
    /// Greater than (>)
    Gt,
    /// Greater than or equal (>=)
    Ge,
    /// Equal (==)
    Eq,
    /// Not equal (!=)
    Ne,
}

impl ComparisonOp {
    /// Evaluate the comparison for two f64 values
    pub fn evaluate(&self, lhs: f64, rhs: f64) -> bool {
        match self {
            ComparisonOp::Lt => lhs < rhs,
            ComparisonOp::Le => lhs <= rhs,
            ComparisonOp::Gt => lhs > rhs,
            ComparisonOp::Ge => lhs >= rhs,
            ComparisonOp::Eq => (lhs - rhs).abs() < 1e-10,
            ComparisonOp::Ne => (lhs - rhs).abs() >= 1e-10,
        }
    }

    /// Get the string representation
    pub fn as_str(&self) -> &'static str {
        match self {
            ComparisonOp::Lt => "<",
            ComparisonOp::Le => "<=",
            ComparisonOp::Gt => ">",
            ComparisonOp::Ge => ">=",
            ComparisonOp::Eq => "==",
            ComparisonOp::Ne => "!=",
        }
    }
}

/// A value in an expression
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Value {
    /// A field reference
    Field(String),
    /// A numeric literal
    Number(f64),
    /// A string literal
    String(String),
    /// A function call
    Function(FunctionCall),
}

/// A function call
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FunctionCall {
    /// Function name
    pub name: String,
    /// Arguments
    pub args: Vec<Value>,
}

impl FunctionCall {
    /// Create a new function call
    pub fn new(name: impl Into<String>, args: Vec<Value>) -> Self {
        Self {
            name: name.into(),
            args,
        }
    }

    /// Create a zscore(field) call
    pub fn zscore(field: &str) -> Self {
        Self::new("zscore", vec![Value::Field(field.to_string())])
    }

    /// Create a percentile(field, p) call
    pub fn percentile(field: &str, p: f64) -> Self {
        Self::new(
            "percentile",
            vec![Value::Field(field.to_string()), Value::Number(p)],
        )
    }
}

/// A geometric primitive for spatial selection
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum GeometricPrimitive {
    /// Sphere defined by center and radius
    Sphere { center: [f64; 3], radius: f64 },

    /// Axis-aligned bounding box
    Box { min: [f64; 3], max: [f64; 3] },

    /// Infinite plane defined by point and normal
    Plane { point: [f64; 3], normal: [f64; 3] },

    /// Cylinder along an axis
    Cylinder {
        center: [f64; 3],
        axis: [f64; 3],
        radius: f64,
        height: f64,
    },

    /// 2D polygon (for 2D selections)
    Polygon { vertices: Vec<[f64; 2]> },
}

impl GeometricPrimitive {
    /// Create a sphere
    pub fn sphere(center: [f64; 3], radius: f64) -> Self {
        Self::Sphere { center, radius }
    }

    /// Create an axis-aligned box
    pub fn aabb(min: [f64; 3], max: [f64; 3]) -> Self {
        Self::Box { min, max }
    }

    /// Create a plane
    pub fn plane(point: [f64; 3], normal: [f64; 3]) -> Self {
        Self::Plane { point, normal }
    }

    /// Test if a point is inside the primitive
    pub fn contains(&self, point: &[f64; 3]) -> bool {
        match self {
            Self::Sphere { center, radius } => {
                let d2 = (point[0] - center[0]).powi(2)
                    + (point[1] - center[1]).powi(2)
                    + (point[2] - center[2]).powi(2);
                d2 <= radius * radius
            }
            Self::Box { min, max } => (0..3).all(|i| point[i] >= min[i] && point[i] <= max[i]),
            Self::Plane { point: p, normal } => {
                let d = (point[0] - p[0]) * normal[0]
                    + (point[1] - p[1]) * normal[1]
                    + (point[2] - p[2]) * normal[2];
                d >= 0.0
            }
            Self::Cylinder {
                center,
                axis,
                radius,
                height,
            } => {
                // Project point onto axis
                let v = [
                    point[0] - center[0],
                    point[1] - center[1],
                    point[2] - center[2],
                ];
                let axis_len2 = axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2];
                let t = (v[0] * axis[0] + v[1] * axis[1] + v[2] * axis[2]) / axis_len2;

                // Check height
                if t < 0.0 || t > *height {
                    return false;
                }

                // Check radius
                let closest = [
                    center[0] + t * axis[0],
                    center[1] + t * axis[1],
                    center[2] + t * axis[2],
                ];
                let d2 = (point[0] - closest[0]).powi(2)
                    + (point[1] - closest[1]).powi(2)
                    + (point[2] - closest[2]).powi(2);
                d2 <= radius * radius
            }
            Self::Polygon { vertices } => {
                // 2D point-in-polygon using ray casting
                let x = point[0];
                let y = point[1];
                let n = vertices.len();
                let mut inside = false;

                let mut j = n - 1;
                for i in 0..n {
                    let xi = vertices[i][0];
                    let yi = vertices[i][1];
                    let xj = vertices[j][0];
                    let yj = vertices[j][1];

                    if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
                        inside = !inside;
                    }
                    j = i;
                }
                inside
            }
        }
    }
}

/// A statistical filter
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum StatisticalFilter {
    /// Z-score filter: |zscore(field)| < threshold
    ZScore { field: String, threshold: f64 },

    /// Percentile filter: field in [low_pct, high_pct]
    Percentile { field: String, low: f64, high: f64 },

    /// Outlier detection: |robust_zscore(field)| < threshold
    RobustOutlier { field: String, threshold: f64 },
}

impl StatisticalFilter {
    /// Create a z-score filter (|z| < threshold)
    pub fn zscore(field: &str, threshold: f64) -> Self {
        Self::ZScore {
            field: field.to_string(),
            threshold,
        }
    }

    /// Create a percentile filter (value in [low, high] percentile)
    pub fn percentile(field: &str, low: f64, high: f64) -> Self {
        Self::Percentile {
            field: field.to_string(),
            low,
            high,
        }
    }

    /// Create a robust outlier filter
    pub fn robust_outlier(field: &str, threshold: f64) -> Self {
        Self::RobustOutlier {
            field: field.to_string(),
            threshold,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_comparison_operators() {
        assert!(ComparisonOp::Lt.evaluate(1.0, 2.0));
        assert!(!ComparisonOp::Lt.evaluate(2.0, 1.0));
        assert!(ComparisonOp::Le.evaluate(1.0, 1.0));
        assert!(ComparisonOp::Gt.evaluate(2.0, 1.0));
        assert!(ComparisonOp::Eq.evaluate(1.0, 1.0));
    }

    #[test]
    fn test_sphere_contains() {
        let sphere = GeometricPrimitive::sphere([0.0, 0.0, 0.0], 1.0);
        assert!(sphere.contains(&[0.0, 0.0, 0.0]));
        assert!(sphere.contains(&[0.5, 0.5, 0.5]));
        assert!(!sphere.contains(&[1.5, 0.0, 0.0]));
    }

    #[test]
    fn test_box_contains() {
        let aabb = GeometricPrimitive::aabb([0.0, 0.0, 0.0], [1.0, 1.0, 1.0]);
        assert!(aabb.contains(&[0.5, 0.5, 0.5]));
        assert!(!aabb.contains(&[-0.5, 0.5, 0.5]));
    }

    #[test]
    fn test_polygon_contains() {
        let polygon = GeometricPrimitive::Polygon {
            vertices: vec![[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]],
        };
        assert!(polygon.contains(&[0.5, 0.5, 0.0]));
        assert!(!polygon.contains(&[-0.5, 0.5, 0.0]));
    }
}
