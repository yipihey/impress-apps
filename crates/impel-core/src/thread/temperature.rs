//! Temperature-based attention gradients
//!
//! Temperature represents the attention priority for a thread (0.0-1.0).
//! Higher temperature means higher priority.
//!
//! Formula:
//! ```text
//! temperature = base_priority
//!             + α × recent_activity
//!             + β × breakthrough_signals
//!             - γ × time_since_progress
//!             + δ × human_boost
//! ```
//!
//! Decay half-life: 24 hours

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

/// Temperature coefficients for the attention formula
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct TemperatureCoefficients {
    /// α: Weight for recent activity
    pub alpha: f64,
    /// β: Weight for breakthrough signals
    pub beta: f64,
    /// γ: Weight for time since progress (decay)
    pub gamma: f64,
    /// δ: Weight for human boost
    pub delta: f64,
}

impl Default for TemperatureCoefficients {
    fn default() -> Self {
        Self {
            alpha: 0.2,
            beta: 0.3,
            gamma: 0.1,
            delta: 0.5,
        }
    }
}

/// Temperature value with decay tracking
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Temperature {
    /// Current temperature value (0.0-1.0)
    value: f64,
    /// Base priority for the thread
    base_priority: f64,
    /// Last update timestamp
    last_updated: DateTime<Utc>,
    /// Human boost factor (decays separately)
    human_boost: f64,
    /// Breakthrough signal strength
    breakthrough_signal: f64,
}

/// Half-life for temperature decay (24 hours)
const DECAY_HALF_LIFE_HOURS: i64 = 24;

impl Temperature {
    /// Create a new temperature with the given initial value
    pub fn new(initial_value: f64) -> Self {
        Self {
            value: initial_value.clamp(0.0, 1.0),
            base_priority: initial_value.clamp(0.0, 1.0),
            last_updated: Utc::now(),
            human_boost: 0.0,
            breakthrough_signal: 0.0,
        }
    }

    /// Create a temperature with custom base priority
    pub fn with_priority(base_priority: f64) -> Self {
        Self {
            value: base_priority.clamp(0.0, 1.0),
            base_priority: base_priority.clamp(0.0, 1.0),
            last_updated: Utc::now(),
            human_boost: 0.0,
            breakthrough_signal: 0.0,
        }
    }

    /// Get the current temperature value
    pub fn value(&self) -> f64 {
        self.value
    }

    /// Get the base priority
    pub fn base_priority(&self) -> f64 {
        self.base_priority
    }

    /// Apply exponential decay based on time elapsed
    pub fn decay(&mut self, elapsed: Duration) {
        let hours = elapsed.num_hours() as f64;
        let decay_factor = 0.5_f64.powf(hours / DECAY_HALF_LIFE_HOURS as f64);
        self.value *= decay_factor;
        self.human_boost *= decay_factor;
        self.breakthrough_signal *= decay_factor;
        self.last_updated = Utc::now();
    }

    /// Update temperature with new activity
    pub fn record_activity(&mut self, activity_weight: f64, coefficients: &TemperatureCoefficients) {
        self.value += coefficients.alpha * activity_weight;
        self.value = self.value.clamp(0.0, 1.0);
        self.last_updated = Utc::now();
    }

    /// Record a breakthrough signal
    pub fn record_breakthrough(&mut self, signal_strength: f64, coefficients: &TemperatureCoefficients) {
        self.breakthrough_signal = signal_strength.clamp(0.0, 1.0);
        self.value += coefficients.beta * self.breakthrough_signal;
        self.value = self.value.clamp(0.0, 1.0);
        self.last_updated = Utc::now();
    }

    /// Apply a human boost (from escalation acknowledgment or priority change)
    pub fn apply_human_boost(&mut self, boost: f64, coefficients: &TemperatureCoefficients) {
        self.human_boost = boost.clamp(0.0, 1.0);
        self.value += coefficients.delta * self.human_boost;
        self.value = self.value.clamp(0.0, 1.0);
        self.last_updated = Utc::now();
    }

    /// Reset temperature to base priority
    pub fn reset(&mut self) {
        self.value = self.base_priority;
        self.human_boost = 0.0;
        self.breakthrough_signal = 0.0;
        self.last_updated = Utc::now();
    }

    /// Recalculate temperature using all components
    pub fn recalculate(&mut self, recent_activity: f64, coefficients: &TemperatureCoefficients) {
        let elapsed = Utc::now() - self.last_updated;
        let hours_since_progress = elapsed.num_hours() as f64;

        self.value = self.base_priority
            + coefficients.alpha * recent_activity
            + coefficients.beta * self.breakthrough_signal
            - coefficients.gamma * (hours_since_progress / DECAY_HALF_LIFE_HOURS as f64)
            + coefficients.delta * self.human_boost;

        self.value = self.value.clamp(0.0, 1.0);
        self.last_updated = Utc::now();
    }

    /// Get the time since last update
    pub fn time_since_update(&self) -> Duration {
        Utc::now() - self.last_updated
    }

    /// Check if temperature is considered "hot" (high priority)
    pub fn is_hot(&self) -> bool {
        self.value >= 0.7
    }

    /// Check if temperature is considered "warm" (medium priority)
    pub fn is_warm(&self) -> bool {
        self.value >= 0.3 && self.value < 0.7
    }

    /// Check if temperature is considered "cold" (low priority)
    pub fn is_cold(&self) -> bool {
        self.value < 0.3
    }
}

impl Default for Temperature {
    fn default() -> Self {
        Self::new(0.5)
    }
}

impl PartialEq for Temperature {
    fn eq(&self, other: &Self) -> bool {
        (self.value - other.value).abs() < f64::EPSILON
    }
}

impl PartialOrd for Temperature {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        self.value.partial_cmp(&other.value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_temperature() {
        let temp = Temperature::new(0.5);
        assert!((temp.value() - 0.5).abs() < f64::EPSILON);
    }

    #[test]
    fn test_temperature_clamping() {
        let temp1 = Temperature::new(1.5);
        assert!((temp1.value() - 1.0).abs() < f64::EPSILON);

        let temp2 = Temperature::new(-0.5);
        assert!((temp2.value() - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_decay() {
        let mut temp = Temperature::new(1.0);
        temp.decay(Duration::hours(24));
        // After one half-life, should be ~0.5
        assert!((temp.value() - 0.5).abs() < 0.01);
    }

    #[test]
    fn test_human_boost() {
        let mut temp = Temperature::new(0.3);
        let coefficients = TemperatureCoefficients::default();
        temp.apply_human_boost(0.5, &coefficients);
        // Should increase by delta * 0.5 = 0.25
        assert!(temp.value() > 0.3);
    }

    #[test]
    fn test_hot_warm_cold() {
        let hot = Temperature::new(0.8);
        let warm = Temperature::new(0.5);
        let cold = Temperature::new(0.1);

        assert!(hot.is_hot());
        assert!(!hot.is_warm());
        assert!(!hot.is_cold());

        assert!(!warm.is_hot());
        assert!(warm.is_warm());
        assert!(!warm.is_cold());

        assert!(!cold.is_hot());
        assert!(!cold.is_warm());
        assert!(cold.is_cold());
    }
}
