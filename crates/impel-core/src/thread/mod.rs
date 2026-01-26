//! Thread management for research threads
//!
//! A thread represents a unit of work in the impel system. Threads go through
//! a state machine lifecycle and have temperature-based attention prioritization.

mod state;
mod temperature;
mod thread;

pub use state::ThreadState;
pub use temperature::{Temperature, TemperatureCoefficients};
pub use thread::{Thread, ThreadId, ThreadMetadata};
