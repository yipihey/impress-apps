//! Who wrote a row, and on which side of the ADR-0031 D7 line.
//!
//! The one copy of these, used by this crate's store and by
//! `impress-surface-service`'s (review RS-S21), which already depends on this
//! crate for `surface_show`'s composed verbs. They cannot live in
//! `impress-service-core` with the report types: they speak the store's
//! vocabulary (`ActorKind`, `RetentionTier`, `OperationIntent`), and that
//! crate is on the kit's pure tier, which may not reach `impress-core`
//! (docs/kit-manifest.md).

use impress_core::item::ActorKind;
use impress_core::operation::{OperationIntent, RetentionTier};

/// Which side of the ADR-0031 D7 line a write is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ephemerality {
    /// A gesture: arrangement, content, selection, a surface's state.
    /// Coalesced and compacted.
    Exploration,
    /// A commit: a saved layout, a materialized binding, a surface's spec.
    /// Kept forever.
    Commit,
}

impl Ephemerality {
    pub fn retention(self) -> RetentionTier {
        match self {
            Ephemerality::Exploration => RetentionTier::Ephemeral,
            Ephemerality::Commit => RetentionTier::Durable,
        }
    }

    pub fn intent(self) -> OperationIntent {
        match self {
            Ephemerality::Exploration => OperationIntent::Routine,
            // A commit is a decision about how work is arranged, which is what
            // `Editorial` means in the ADR-0003 vocabulary.
            Ephemerality::Commit => OperationIntent::Editorial,
        }
    }
}

/// The author string a service writes with an operation: `IMPRESS_AUTHOR`
/// when set, so a host that knows who the user is can say so; otherwise
/// `<actor>:<service>` (`human:layout-service`, `agent:surface-service`).
/// The actor kind is the whole of what is known, and saying that plainly
/// beats inventing an identity.
pub fn author_for_service(actor: ActorKind, service: &str) -> String {
    if let Ok(author) = std::env::var("IMPRESS_AUTHOR") {
        let author = author.trim();
        if !author.is_empty() {
            return author.to_string();
        }
    }
    let kind = match actor {
        ActorKind::Human => "human",
        ActorKind::Agent => "agent",
        ActorKind::System => "system",
    };
    format!("{kind}:{service}")
}

/// Parse an actor argument. `None` means [`ActorKind::Agent`]: these verbs
/// reach the store over MCP and the CLI, and an agent that forgets to say who
/// it is must not be recorded as the user.
pub fn actor_from(raw: Option<&str>) -> ActorKind {
    match raw.map(|a| a.trim().to_ascii_lowercase()).as_deref() {
        Some("human") | Some("user") | Some("person") => ActorKind::Human,
        Some("system") => ActorKind::System,
        _ => ActorKind::Agent,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The strings every row already written carries; a change here would
    /// split one author into two in history.
    #[test]
    fn the_author_names_the_actor_and_the_service() {
        if std::env::var("IMPRESS_AUTHOR").is_ok() {
            return;
        }
        assert_eq!(
            author_for_service(ActorKind::Human, "layout-service"),
            "human:layout-service"
        );
        assert_eq!(
            author_for_service(ActorKind::Agent, "surface-service"),
            "agent:surface-service"
        );
        assert_eq!(
            author_for_service(ActorKind::System, "layout-service"),
            "system:layout-service"
        );
    }

    #[test]
    fn a_missing_or_unknown_actor_is_an_agent() {
        assert_eq!(actor_from(None), ActorKind::Agent);
        assert_eq!(actor_from(Some("robot")), ActorKind::Agent);
        assert_eq!(actor_from(Some(" User ")), ActorKind::Human);
        assert_eq!(actor_from(Some("system")), ActorKind::System);
    }
}
