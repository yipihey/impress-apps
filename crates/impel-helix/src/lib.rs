//! Helix-style modal editing for terminal text interfaces.
//!
//! This crate provides a Rust implementation of Helix-style modal editing,
//! mirroring the ImpressModalEditing Swift package for cross-platform consistency
//! across the Impress suite.
//!
//! # Example
//!
//! ```
//! use impel_helix::{HelixState, HelixMode, HelixKeyHandler, HelixKeyResult, KeyModifiers};
//!
//! let mut state = HelixState::new();
//! let mut handler = HelixKeyHandler::new();
//! let modifiers = KeyModifiers::default();
//!
//! // Handle a key press
//! match handler.handle_key('j', state.mode(), &modifiers) {
//!     HelixKeyResult::Command(command) => {
//!         println!("Got command: {:?}", command);
//!     }
//!     HelixKeyResult::Pending => {
//!         println!("Waiting for more input...");
//!     }
//!     _ => {}
//! }
//! ```

mod mode;
mod command;
mod key_handler;
mod state;
mod text_engine;

pub use mode::HelixMode;
pub use command::HelixCommand;
pub use key_handler::{HelixKeyHandler, HelixKeyResult, KeyModifiers, PendingCharacterOperation};
pub use state::HelixState;
pub use text_engine::HelixTextEngine;
