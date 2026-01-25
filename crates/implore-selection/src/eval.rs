//! Expression evaluation for selection
//!
//! Evaluates selection expressions against dataset values.

use crate::ast::*;
use std::collections::HashMap;
use thiserror::Error;

/// Evaluation errors
#[derive(Debug, Error)]
pub enum EvalError {
    #[error("Field not found: {0}")]
    FieldNotFound(String),

    #[error("Type error: {0}")]
    TypeError(String),

    #[error("Unknown function: {0}")]
    UnknownFunction(String),

    #[error("Register not found: {0}")]
    RegisterNotFound(String),

    #[error("Invalid arguments: {0}")]
    InvalidArguments(String),
}

/// Result type for evaluation
pub type EvalResult<T> = Result<T, EvalError>;

/// Context for evaluation - provides field values
pub trait EvalContext {
    /// Get the value of a field at a point index
    fn field_value(&self, field: &str, index: usize) -> Option<f64>;

    /// Get the 3D position of a point
    fn point_position(&self, index: usize) -> Option<[f64; 3]>;

    /// Get the number of points
    fn num_points(&self) -> usize;

    /// Get computed statistics for a field
    fn field_stats(&self, field: &str) -> Option<&FieldStats>;
}

/// Pre-computed statistics for a field
#[derive(Debug, Clone)]
pub struct FieldStats {
    pub mean: f64,
    pub std_dev: f64,
    pub median: f64,
    pub mad: f64,
    pub percentiles: [f64; 101], // 0th to 100th percentile
}

impl FieldStats {
    /// Compute z-score
    pub fn zscore(&self, value: f64) -> f64 {
        if self.std_dev == 0.0 {
            return 0.0;
        }
        (value - self.mean) / self.std_dev
    }

    /// Compute robust z-score (using median and MAD)
    pub fn robust_zscore(&self, value: f64) -> f64 {
        if self.mad == 0.0 {
            return 0.0;
        }
        (value - self.median) / (1.4826 * self.mad)
    }

    /// Get percentile value
    pub fn percentile(&self, p: f64) -> f64 {
        let p = p.clamp(0.0, 100.0);
        let idx = p.floor() as usize;
        let frac = p.fract();

        if idx >= 100 {
            self.percentiles[100]
        } else {
            self.percentiles[idx] * (1.0 - frac) + self.percentiles[idx + 1] * frac
        }
    }
}

/// Evaluator for selection expressions
pub struct Evaluator<'a, C: EvalContext> {
    context: &'a C,
    registers: HashMap<String, Vec<bool>>,
}

impl<'a, C: EvalContext> Evaluator<'a, C> {
    /// Create a new evaluator
    pub fn new(context: &'a C) -> Self {
        Self {
            context,
            registers: HashMap::new(),
        }
    }

    /// Store a selection in a register
    pub fn store_register(&mut self, name: impl Into<String>, mask: Vec<bool>) {
        self.registers.insert(name.into(), mask);
    }

    /// Evaluate an expression, returning a selection mask
    pub fn evaluate(&self, expr: &SelectionExpr) -> EvalResult<Vec<bool>> {
        let n = self.context.num_points();
        let mut result = vec![false; n];

        for i in 0..n {
            result[i] = self.evaluate_at(expr, i)?;
        }

        Ok(result)
    }

    /// Evaluate an expression at a single point index
    pub fn evaluate_at(&self, expr: &SelectionExpr, index: usize) -> EvalResult<bool> {
        match expr {
            SelectionExpr::All => Ok(true),
            SelectionExpr::None => Ok(false),

            SelectionExpr::And(left, right) => {
                Ok(self.evaluate_at(left, index)? && self.evaluate_at(right, index)?)
            }

            SelectionExpr::Or(left, right) => {
                Ok(self.evaluate_at(left, index)? || self.evaluate_at(right, index)?)
            }

            SelectionExpr::Not(inner) => Ok(!self.evaluate_at(inner, index)?),

            SelectionExpr::Comparison(cmp) => self.evaluate_comparison(cmp, index),

            SelectionExpr::Geometric(geom) => self.evaluate_geometric(geom, index),

            SelectionExpr::Statistical(stat) => self.evaluate_statistical(stat, index),

            SelectionExpr::Register(name) => {
                let mask = self
                    .registers
                    .get(name)
                    .ok_or_else(|| EvalError::RegisterNotFound(name.clone()))?;
                Ok(mask.get(index).copied().unwrap_or(false))
            }
        }
    }

    /// Evaluate a comparison predicate
    fn evaluate_comparison(&self, cmp: &Comparison, index: usize) -> EvalResult<bool> {
        let lhs = self.evaluate_value(&cmp.lhs, index)?;
        let rhs = self.evaluate_value(&cmp.rhs, index)?;
        Ok(cmp.op.evaluate(lhs, rhs))
    }

    /// Evaluate a value
    fn evaluate_value(&self, value: &Value, index: usize) -> EvalResult<f64> {
        match value {
            Value::Number(n) => Ok(*n),

            Value::Field(name) => self
                .context
                .field_value(name, index)
                .ok_or_else(|| EvalError::FieldNotFound(name.clone())),

            Value::Function(func) => self.evaluate_function(func, index),

            Value::String(_) => Err(EvalError::TypeError(
                "Cannot use string in numeric comparison".to_string(),
            )),
        }
    }

    /// Evaluate a function call
    fn evaluate_function(&self, func: &FunctionCall, index: usize) -> EvalResult<f64> {
        match func.name.as_str() {
            "zscore" => {
                let field = match func.args.get(0) {
                    Some(Value::Field(f)) => f,
                    _ => {
                        return Err(EvalError::InvalidArguments(
                            "zscore requires a field argument".to_string(),
                        ))
                    }
                };

                let value = self
                    .context
                    .field_value(field, index)
                    .ok_or_else(|| EvalError::FieldNotFound(field.clone()))?;

                let stats = self
                    .context
                    .field_stats(field)
                    .ok_or_else(|| EvalError::FieldNotFound(field.clone()))?;

                Ok(stats.zscore(value))
            }

            "robust_zscore" => {
                let field = match func.args.get(0) {
                    Some(Value::Field(f)) => f,
                    _ => {
                        return Err(EvalError::InvalidArguments(
                            "robust_zscore requires a field argument".to_string(),
                        ))
                    }
                };

                let value = self
                    .context
                    .field_value(field, index)
                    .ok_or_else(|| EvalError::FieldNotFound(field.clone()))?;

                let stats = self
                    .context
                    .field_stats(field)
                    .ok_or_else(|| EvalError::FieldNotFound(field.clone()))?;

                Ok(stats.robust_zscore(value))
            }

            "percentile" => {
                let (field, p) = match (&func.args.get(0), &func.args.get(1)) {
                    (Some(Value::Field(f)), Some(Value::Number(p))) => (f, *p),
                    _ => {
                        return Err(EvalError::InvalidArguments(
                            "percentile requires (field, p) arguments".to_string(),
                        ))
                    }
                };

                let value = self
                    .context
                    .field_value(field, index)
                    .ok_or_else(|| EvalError::FieldNotFound(field.clone()))?;

                let stats = self
                    .context
                    .field_stats(field)
                    .ok_or_else(|| EvalError::FieldNotFound(field.clone()))?;

                // Return how this value compares to the given percentile
                let threshold = stats.percentile(p);
                Ok(if value <= threshold { 1.0 } else { 0.0 })
            }

            "abs" => {
                let value = match func.args.get(0) {
                    Some(v) => self.evaluate_value(v, index)?,
                    None => {
                        return Err(EvalError::InvalidArguments(
                            "abs requires an argument".to_string(),
                        ))
                    }
                };
                Ok(value.abs())
            }

            "sqrt" => {
                let value = match func.args.get(0) {
                    Some(v) => self.evaluate_value(v, index)?,
                    None => {
                        return Err(EvalError::InvalidArguments(
                            "sqrt requires an argument".to_string(),
                        ))
                    }
                };
                Ok(value.sqrt())
            }

            "log10" => {
                let value = match func.args.get(0) {
                    Some(v) => self.evaluate_value(v, index)?,
                    None => {
                        return Err(EvalError::InvalidArguments(
                            "log10 requires an argument".to_string(),
                        ))
                    }
                };
                Ok(value.log10())
            }

            _ => Err(EvalError::UnknownFunction(func.name.clone())),
        }
    }

    /// Evaluate a geometric primitive
    fn evaluate_geometric(&self, geom: &GeometricPrimitive, index: usize) -> EvalResult<bool> {
        let pos = self
            .context
            .point_position(index)
            .ok_or_else(|| EvalError::FieldNotFound("position".to_string()))?;

        Ok(geom.contains(&pos))
    }

    /// Evaluate a statistical filter
    fn evaluate_statistical(&self, stat: &StatisticalFilter, index: usize) -> EvalResult<bool> {
        match stat {
            StatisticalFilter::ZScore { field, threshold } => {
                let value = self
                    .context
                    .field_value(field, index)
                    .ok_or_else(|| EvalError::FieldNotFound(field.clone()))?;

                let stats = self
                    .context
                    .field_stats(field)
                    .ok_or_else(|| EvalError::FieldNotFound(field.clone()))?;

                Ok(stats.zscore(value).abs() < *threshold)
            }

            StatisticalFilter::RobustOutlier { field, threshold } => {
                let value = self
                    .context
                    .field_value(field, index)
                    .ok_or_else(|| EvalError::FieldNotFound(field.clone()))?;

                let stats = self
                    .context
                    .field_stats(field)
                    .ok_or_else(|| EvalError::FieldNotFound(field.clone()))?;

                Ok(stats.robust_zscore(value).abs() < *threshold)
            }

            StatisticalFilter::Percentile { field, low, high } => {
                let value = self
                    .context
                    .field_value(field, index)
                    .ok_or_else(|| EvalError::FieldNotFound(field.clone()))?;

                let stats = self
                    .context
                    .field_stats(field)
                    .ok_or_else(|| EvalError::FieldNotFound(field.clone()))?;

                let low_thresh = stats.percentile(*low);
                let high_thresh = stats.percentile(*high);

                Ok(value >= low_thresh && value <= high_thresh)
            }
        }
    }
}

/// Count the number of selected points
pub fn count_selected(mask: &[bool]) -> usize {
    mask.iter().filter(|&&b| b).count()
}

/// Get indices of selected points
pub fn selected_indices(mask: &[bool]) -> Vec<usize> {
    mask.iter()
        .enumerate()
        .filter_map(|(i, &b)| if b { Some(i) } else { None })
        .collect()
}

/// Invert a selection mask
pub fn invert_mask(mask: &[bool]) -> Vec<bool> {
    mask.iter().map(|&b| !b).collect()
}

/// Combine two masks with AND
pub fn and_masks(a: &[bool], b: &[bool]) -> Vec<bool> {
    a.iter().zip(b.iter()).map(|(&a, &b)| a && b).collect()
}

/// Combine two masks with OR
pub fn or_masks(a: &[bool], b: &[bool]) -> Vec<bool> {
    a.iter().zip(b.iter()).map(|(&a, &b)| a || b).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestContext {
        x: Vec<f64>,
        y: Vec<f64>,
        z: Vec<f64>,
    }

    impl EvalContext for TestContext {
        fn field_value(&self, field: &str, index: usize) -> Option<f64> {
            match field {
                "x" => self.x.get(index).copied(),
                "y" => self.y.get(index).copied(),
                "z" => self.z.get(index).copied(),
                _ => None,
            }
        }

        fn point_position(&self, index: usize) -> Option<[f64; 3]> {
            Some([
                *self.x.get(index)?,
                *self.y.get(index)?,
                *self.z.get(index)?,
            ])
        }

        fn num_points(&self) -> usize {
            self.x.len()
        }

        fn field_stats(&self, _field: &str) -> Option<&FieldStats> {
            None
        }
    }

    #[test]
    fn test_evaluate_comparison() {
        let ctx = TestContext {
            x: vec![1.0, 2.0, 3.0, 4.0, 5.0],
            y: vec![5.0, 4.0, 3.0, 2.0, 1.0],
            z: vec![0.0; 5],
        };

        let eval = Evaluator::new(&ctx);

        let expr = SelectionExpr::Comparison(Comparison::field_gt("x", 2.0));
        let mask = eval.evaluate(&expr).unwrap();

        assert_eq!(mask, vec![false, false, true, true, true]);
    }

    #[test]
    fn test_evaluate_and() {
        let ctx = TestContext {
            x: vec![1.0, 2.0, 3.0, 4.0, 5.0],
            y: vec![5.0, 4.0, 3.0, 2.0, 1.0],
            z: vec![0.0; 5],
        };

        let eval = Evaluator::new(&ctx);

        let expr = SelectionExpr::and(
            SelectionExpr::Comparison(Comparison::field_gt("x", 2.0)),
            SelectionExpr::Comparison(Comparison::field_gt("y", 2.0)),
        );
        let mask = eval.evaluate(&expr).unwrap();

        // x > 2: [F, F, T, T, T]
        // y > 2: [T, T, T, F, F]
        // AND:   [F, F, T, F, F]
        assert_eq!(mask, vec![false, false, true, false, false]);
    }

    #[test]
    fn test_evaluate_sphere() {
        let ctx = TestContext {
            x: vec![0.0, 0.5, 2.0],
            y: vec![0.0, 0.5, 0.0],
            z: vec![0.0, 0.0, 0.0],
        };

        let eval = Evaluator::new(&ctx);

        let expr = SelectionExpr::Geometric(GeometricPrimitive::sphere([0.0, 0.0, 0.0], 1.0));
        let mask = eval.evaluate(&expr).unwrap();

        // (0,0,0) is in, (0.5,0.5,0) is in, (2,0,0) is out
        assert_eq!(mask, vec![true, true, false]);
    }

    #[test]
    fn test_count_selected() {
        let mask = vec![true, false, true, false, true];
        assert_eq!(count_selected(&mask), 3);
    }

    #[test]
    fn test_selected_indices() {
        let mask = vec![true, false, true, false, true];
        assert_eq!(selected_indices(&mask), vec![0, 2, 4]);
    }
}
