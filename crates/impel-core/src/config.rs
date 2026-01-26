//! Configuration for impel-core
//!
//! Centralized configuration for system parameters including temperature
//! coefficients, timing, and behavior settings.

use serde::{Deserialize, Serialize};

use crate::thread::TemperatureCoefficients;

/// System-wide configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ImpelConfig {
    /// Temperature calculation parameters
    pub temperature: TemperatureConfig,
    /// Agent behavior settings
    pub agent: AgentConfig,
    /// Escalation settings
    pub escalation: EscalationConfig,
    /// System timing settings
    pub timing: TimingConfig,
}

impl Default for ImpelConfig {
    fn default() -> Self {
        Self {
            temperature: TemperatureConfig::default(),
            agent: AgentConfig::default(),
            escalation: EscalationConfig::default(),
            timing: TimingConfig::default(),
        }
    }
}

/// Temperature calculation configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct TemperatureConfig {
    /// Coefficients for the temperature formula
    pub coefficients: TemperatureCoefficients,
    /// Half-life for temperature decay in hours
    pub decay_half_life_hours: u32,
    /// Window for recent activity calculation in hours
    pub activity_window_hours: u32,
    /// Window for breakthrough signal calculation in days
    pub breakthrough_window_days: u32,
    /// Threshold for "hot" temperature
    pub hot_threshold: f64,
    /// Threshold for "warm" temperature (below this is "cold")
    pub warm_threshold: f64,
}

impl Default for TemperatureConfig {
    fn default() -> Self {
        Self {
            coefficients: TemperatureCoefficients::default(),
            decay_half_life_hours: 24,
            activity_window_hours: 24,
            breakthrough_window_days: 7,
            hot_threshold: 0.7,
            warm_threshold: 0.3,
        }
    }
}

/// Agent behavior configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct AgentConfig {
    /// Maximum concurrent agents per thread
    pub max_agents_per_thread: u32,
    /// Claim expiry time in minutes
    pub claim_expiry_minutes: u32,
    /// Cool-down period between cycles in seconds
    pub cooldown_seconds: u32,
    /// Maximum cycle duration in minutes
    pub max_cycle_duration_minutes: u32,
    /// Maximum retries before escalation
    pub max_retries: u32,
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            max_agents_per_thread: 3,
            claim_expiry_minutes: 30,
            cooldown_seconds: 60,
            max_cycle_duration_minutes: 120,
            max_retries: 3,
        }
    }
}

/// Escalation behavior configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct EscalationConfig {
    /// Auto-escalate after this many blocked cycles
    pub auto_escalate_after_cycles: u32,
    /// Expected response times by priority (in hours)
    pub response_time_low_hours: u32,
    pub response_time_medium_hours: u32,
    pub response_time_high_hours: u32,
    pub response_time_critical_hours: u32,
    /// Maximum open escalations before warning
    pub max_open_escalations_warning: u32,
}

impl Default for EscalationConfig {
    fn default() -> Self {
        Self {
            auto_escalate_after_cycles: 2,
            response_time_low_hours: 168, // 1 week
            response_time_medium_hours: 24,
            response_time_high_hours: 4,
            response_time_critical_hours: 1,
            max_open_escalations_warning: 10,
        }
    }
}

/// System timing configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct TimingConfig {
    /// Temperature recalculation interval in minutes
    pub temperature_recalc_minutes: u32,
    /// State snapshot interval in minutes
    pub snapshot_interval_minutes: u32,
    /// Event retention period in days
    pub event_retention_days: u32,
}

impl Default for TimingConfig {
    fn default() -> Self {
        Self {
            temperature_recalc_minutes: 5,
            snapshot_interval_minutes: 60,
            event_retention_days: 365,
        }
    }
}

impl ImpelConfig {
    /// Create a new configuration with defaults
    pub fn new() -> Self {
        Self::default()
    }

    /// Load configuration from a TOML string
    #[cfg(feature = "toml-config")]
    pub fn from_toml(toml_str: &str) -> Result<Self, toml::de::Error> {
        toml::from_str(toml_str)
    }

    /// Serialize configuration to TOML
    #[cfg(feature = "toml-config")]
    pub fn to_toml(&self) -> Result<String, toml::ser::Error> {
        toml::to_string_pretty(self)
    }

    /// Load configuration from a JSON string
    pub fn from_json(json_str: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json_str)
    }

    /// Serialize configuration to JSON
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }

    /// Validate configuration values
    pub fn validate(&self) -> Result<(), ConfigError> {
        // Temperature thresholds must be in valid range
        if self.temperature.hot_threshold <= self.temperature.warm_threshold {
            return Err(ConfigError::InvalidThresholds(
                "hot_threshold must be greater than warm_threshold".to_string(),
            ));
        }

        if self.temperature.hot_threshold > 1.0 || self.temperature.hot_threshold < 0.0 {
            return Err(ConfigError::OutOfRange(
                "hot_threshold must be between 0.0 and 1.0".to_string(),
            ));
        }

        if self.temperature.warm_threshold > 1.0 || self.temperature.warm_threshold < 0.0 {
            return Err(ConfigError::OutOfRange(
                "warm_threshold must be between 0.0 and 1.0".to_string(),
            ));
        }

        // Decay half-life must be positive
        if self.temperature.decay_half_life_hours == 0 {
            return Err(ConfigError::OutOfRange(
                "decay_half_life_hours must be positive".to_string(),
            ));
        }

        Ok(())
    }
}

/// Configuration validation error
#[derive(Debug, Clone)]
pub enum ConfigError {
    /// Threshold values are invalid relative to each other
    InvalidThresholds(String),
    /// Value is out of valid range
    OutOfRange(String),
    /// Required field is missing
    MissingField(String),
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConfigError::InvalidThresholds(msg) => write!(f, "Invalid thresholds: {}", msg),
            ConfigError::OutOfRange(msg) => write!(f, "Value out of range: {}", msg),
            ConfigError::MissingField(msg) => write!(f, "Missing field: {}", msg),
        }
    }
}

impl std::error::Error for ConfigError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = ImpelConfig::default();
        assert!(config.validate().is_ok());
    }

    #[test]
    fn test_json_serialization() {
        let config = ImpelConfig::default();
        let json = config.to_json().unwrap();
        let parsed: ImpelConfig = ImpelConfig::from_json(&json).unwrap();
        assert_eq!(config.temperature.hot_threshold, parsed.temperature.hot_threshold);
    }

    #[test]
    fn test_invalid_thresholds() {
        let mut config = ImpelConfig::default();
        config.temperature.hot_threshold = 0.3;
        config.temperature.warm_threshold = 0.7;
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_out_of_range() {
        let mut config = ImpelConfig::default();
        config.temperature.hot_threshold = 1.5;
        assert!(config.validate().is_err());
    }
}
