//! Escalation management for human intervention
//!
//! Escalations are requests for human attention, categorized by type
//! and prioritized based on urgency and impact.

mod category;

pub use category::{
    Escalation, EscalationCategory, EscalationOption, EscalationPriority, EscalationStatus,
};
