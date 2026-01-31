//! Email threading using the JWZ algorithm.
//!
//! Implements Jamie Zawinski's threading algorithm as described at:
//! https://www.jwz.org/doc/threading.html
//!
//! This is the standard algorithm used by email clients like Mutt,
//! Mozilla Thunderbird, and Apple Mail.

use crate::types::{Envelope, Thread};
use std::collections::{HashMap, HashSet};

// MARK: - Threading

/// Thread a list of messages using the JWZ algorithm.
///
/// Returns a list of threads, each containing message IDs in thread order.
pub fn thread_messages(envelopes: &[Envelope]) -> Vec<Thread> {
    if envelopes.is_empty() {
        return Vec::new();
    }

    // Step 1: Build ID table
    let mut id_table: HashMap<String, Container> = HashMap::new();

    for envelope in envelopes {
        let message_id = match &envelope.message_id {
            Some(id) => normalize_message_id(id),
            None => continue, // Skip messages without Message-ID
        };

        // Create container for this message
        let container = id_table.entry(message_id.clone()).or_insert_with(|| {
            Container::new(message_id.clone())
        });
        container.envelope = Some(envelope.clone());

        // Process References header to build parent chain
        let mut parent_id: Option<String> = None;

        for reference in &envelope.references {
            let ref_id = normalize_message_id(reference);

            // Get or create container for this reference
            id_table.entry(ref_id.clone()).or_insert_with(|| {
                Container::new(ref_id.clone())
            });

            // Link parent to child
            if let Some(pid) = &parent_id {
                let parent = id_table.get_mut(pid).unwrap();
                if !parent.children.contains(&ref_id) {
                    parent.children.push(ref_id.clone());
                }
            }

            parent_id = Some(ref_id);
        }

        // Link last reference as parent of this message
        if let Some(pid) = &parent_id {
            if pid != &message_id {
                let parent = id_table.get_mut(pid).unwrap();
                if !parent.children.contains(&message_id) {
                    parent.children.push(message_id.clone());
                }
            }
        }

        // Also check In-Reply-To
        if let Some(in_reply_to) = &envelope.in_reply_to {
            let reply_id = normalize_message_id(in_reply_to);
            if reply_id != message_id {
                let parent = id_table.entry(reply_id.clone()).or_insert_with(|| {
                    Container::new(reply_id.clone())
                });
                if !parent.children.contains(&message_id) {
                    parent.children.push(message_id.clone());
                }
            }
        }
    }

    // Step 2: Find root containers (those not referenced by others)
    let all_children: HashSet<String> = id_table
        .values()
        .flat_map(|c| c.children.iter().cloned())
        .collect();

    let roots: Vec<String> = id_table
        .keys()
        .filter(|id| !all_children.contains(*id))
        .cloned()
        .collect();

    // Step 3: Build threads from roots
    let mut threads: Vec<Thread> = Vec::new();

    for root_id in roots {
        if let Some(container) = id_table.get(&root_id) {
            // Only include if there's at least one real message
            let message_ids = collect_message_ids(container, &id_table);
            if !message_ids.is_empty() {
                let subject = container
                    .envelope
                    .as_ref()
                    .and_then(|e| e.subject.clone());

                threads.push(Thread {
                    root_message_id: root_id,
                    message_ids,
                    subject,
                });
            }
        }
    }

    // Sort threads by date (most recent first)
    threads.sort_by(|a, b| {
        let date_a = id_table
            .get(&a.root_message_id)
            .and_then(|c| c.envelope.as_ref())
            .and_then(|e| e.date);
        let date_b = id_table
            .get(&b.root_message_id)
            .and_then(|c| c.envelope.as_ref())
            .and_then(|e| e.date);
        date_b.cmp(&date_a)
    });

    threads
}

/// Container for the JWZ algorithm.
#[derive(Debug)]
struct Container {
    /// Message ID.
    message_id: String,

    /// Envelope if this container has a message.
    envelope: Option<Envelope>,

    /// Child message IDs.
    children: Vec<String>,
}

impl Container {
    fn new(message_id: String) -> Self {
        Self {
            message_id,
            envelope: None,
            children: Vec::new(),
        }
    }
}

/// Normalize a message ID (remove angle brackets, lowercase).
fn normalize_message_id(id: &str) -> String {
    id.trim()
        .trim_matches(|c| c == '<' || c == '>')
        .to_lowercase()
}

/// Collect all message IDs from a container and its children.
fn collect_message_ids(container: &Container, id_table: &HashMap<String, Container>) -> Vec<String> {
    let mut result = Vec::new();
    collect_message_ids_recursive(container, id_table, &mut result, &mut HashSet::new());
    result
}

fn collect_message_ids_recursive(
    container: &Container,
    id_table: &HashMap<String, Container>,
    result: &mut Vec<String>,
    visited: &mut HashSet<String>,
) {
    // Avoid cycles
    if visited.contains(&container.message_id) {
        return;
    }
    visited.insert(container.message_id.clone());

    // Add this message if it has an envelope
    if container.envelope.is_some() {
        result.push(container.message_id.clone());
    }

    // Recurse into children
    for child_id in &container.children {
        if let Some(child) = id_table.get(child_id) {
            collect_message_ids_recursive(child, id_table, result, visited);
        }
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn make_envelope(uid: u32, message_id: &str, in_reply_to: Option<&str>, references: &[&str]) -> Envelope {
        Envelope {
            uid,
            message_id: Some(message_id.to_string()),
            in_reply_to: in_reply_to.map(|s| s.to_string()),
            references: references.iter().map(|s| s.to_string()).collect(),
            subject: Some(format!("Message {}", uid)),
            from: Vec::new(),
            to: Vec::new(),
            cc: Vec::new(),
            bcc: Vec::new(),
            date: None,
            flags: Vec::new(),
        }
    }

    #[test]
    fn test_single_message() {
        let envelopes = vec![make_envelope(1, "<msg1@example.com>", None, &[])];
        let threads = thread_messages(&envelopes);

        assert_eq!(threads.len(), 1);
        assert_eq!(threads[0].message_ids.len(), 1);
    }

    #[test]
    fn test_simple_reply() {
        let envelopes = vec![
            make_envelope(1, "<msg1@example.com>", None, &[]),
            make_envelope(
                2,
                "<msg2@example.com>",
                Some("<msg1@example.com>"),
                &["<msg1@example.com>"],
            ),
        ];
        let threads = thread_messages(&envelopes);

        assert_eq!(threads.len(), 1);
        assert_eq!(threads[0].message_ids.len(), 2);
    }

    #[test]
    fn test_multiple_threads() {
        let envelopes = vec![
            make_envelope(1, "<thread1@example.com>", None, &[]),
            make_envelope(2, "<thread2@example.com>", None, &[]),
        ];
        let threads = thread_messages(&envelopes);

        assert_eq!(threads.len(), 2);
    }

    #[test]
    fn test_normalize_message_id() {
        assert_eq!(
            normalize_message_id("<MSG@Example.COM>"),
            "msg@example.com"
        );
        assert_eq!(normalize_message_id("  <test>  "), "test");
    }
}
