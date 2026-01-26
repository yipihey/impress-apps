//! Message threading using In-Reply-To chains

use std::collections::HashMap;

use super::{MessageEnvelope, MessageId};

/// A thread of messages reconstructed from In-Reply-To chains
#[derive(Debug, Default)]
pub struct MessageThread {
    /// Root messages (messages with no In-Reply-To)
    roots: Vec<MessageId>,
    /// Map from message ID to message
    messages: HashMap<MessageId, MessageEnvelope>,
    /// Map from message ID to child message IDs
    children: HashMap<MessageId, Vec<MessageId>>,
}

impl MessageThread {
    /// Create a new empty message thread
    pub fn new() -> Self {
        Self {
            roots: Vec::new(),
            messages: HashMap::new(),
            children: HashMap::new(),
        }
    }

    /// Add a message to the thread
    pub fn add(&mut self, message: MessageEnvelope) {
        let message_id = message.message_id.clone();

        // Check if this is a reply
        if let Some(ref parent_id) = message.in_reply_to {
            self.children
                .entry(parent_id.clone())
                .or_default()
                .push(message_id.clone());
        } else {
            // No parent, this is a root message
            self.roots.push(message_id.clone());
        }

        self.messages.insert(message_id, message);
    }

    /// Get a message by ID
    pub fn get(&self, id: &MessageId) -> Option<&MessageEnvelope> {
        self.messages.get(id)
    }

    /// Get all root messages
    pub fn roots(&self) -> impl Iterator<Item = &MessageEnvelope> {
        self.roots.iter().filter_map(|id| self.messages.get(id))
    }

    /// Get children of a message
    pub fn children_of(&self, id: &MessageId) -> impl Iterator<Item = &MessageEnvelope> {
        self.children
            .get(id)
            .map(|ids| ids.as_slice())
            .unwrap_or(&[])
            .iter()
            .filter_map(|id| self.messages.get(id))
    }

    /// Get the parent of a message
    pub fn parent_of(&self, message: &MessageEnvelope) -> Option<&MessageEnvelope> {
        message
            .in_reply_to
            .as_ref()
            .and_then(|id| self.messages.get(id))
    }

    /// Get all messages in chronological order
    pub fn chronological(&self) -> Vec<&MessageEnvelope> {
        let mut messages: Vec<_> = self.messages.values().collect();
        messages.sort_by_key(|m| m.date);
        messages
    }

    /// Get all messages in threaded order (depth-first traversal)
    pub fn threaded(&self) -> Vec<&MessageEnvelope> {
        let mut result = Vec::new();
        let mut roots: Vec<_> = self.roots().collect();
        roots.sort_by_key(|m| m.date);

        for root in roots {
            self.collect_threaded(root, &mut result);
        }

        result
    }

    fn collect_threaded<'a>(
        &'a self,
        message: &'a MessageEnvelope,
        result: &mut Vec<&'a MessageEnvelope>,
    ) {
        result.push(message);

        let mut children: Vec<_> = self.children_of(&message.message_id).collect();
        children.sort_by_key(|m| m.date);

        for child in children {
            self.collect_threaded(child, result);
        }
    }

    /// Get the depth of a message in the thread
    pub fn depth(&self, message: &MessageEnvelope) -> usize {
        let mut depth = 0;
        let mut current = message;

        while let Some(parent) = self.parent_of(current) {
            depth += 1;
            current = parent;
        }

        depth
    }

    /// Get the total number of messages in the thread
    pub fn len(&self) -> usize {
        self.messages.len()
    }

    /// Check if the thread is empty
    pub fn is_empty(&self) -> bool {
        self.messages.is_empty()
    }

    /// Get thread statistics
    pub fn stats(&self) -> ThreadStats {
        let total = self.messages.len();
        let roots = self.roots.len();
        let max_depth = self
            .messages
            .values()
            .map(|m| self.depth(m))
            .max()
            .unwrap_or(0);

        let participants: std::collections::HashSet<_> = self
            .messages
            .values()
            .map(|m| m.from.email())
            .collect();

        ThreadStats {
            total_messages: total,
            root_messages: roots,
            max_depth,
            participant_count: participants.len(),
        }
    }
}

/// Statistics about a message thread
#[derive(Debug, Clone)]
pub struct ThreadStats {
    /// Total number of messages
    pub total_messages: usize,
    /// Number of root messages (conversation starters)
    pub root_messages: usize,
    /// Maximum reply depth
    pub max_depth: usize,
    /// Number of unique participants
    pub participant_count: usize,
}

/// Build message threads from a collection of messages
pub fn build_threads(messages: Vec<MessageEnvelope>) -> HashMap<String, MessageThread> {
    let mut threads: HashMap<String, MessageThread> = HashMap::new();

    for message in messages {
        // Determine which thread this message belongs to
        let thread_key = if let Some(ref thread_id) = message.thread_id {
            thread_id.to_string()
        } else if !message.references.is_empty() {
            // Use the first reference as the thread key
            message.references[0].raw().to_string()
        } else if let Some(ref in_reply_to) = message.in_reply_to {
            in_reply_to.raw().to_string()
        } else {
            // This is a standalone message, use its own ID as the thread key
            message.message_id.raw().to_string()
        };

        threads
            .entry(thread_key)
            .or_insert_with(MessageThread::new)
            .add(message);
    }

    threads
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::{Address, MessageBody};

    fn create_message(subject: &str) -> MessageEnvelope {
        let from = Address::agent("test");
        let to = vec![Address::agent("recipient")];
        let body = MessageBody::new("Test body".to_string());
        MessageEnvelope::new(from, to, subject.to_string(), body)
    }

    #[test]
    fn test_empty_thread() {
        let thread = MessageThread::new();
        assert!(thread.is_empty());
        assert_eq!(thread.len(), 0);
    }

    #[test]
    fn test_add_root_message() {
        let mut thread = MessageThread::new();
        let msg = create_message("Hello");
        let id = msg.message_id.clone();

        thread.add(msg);
        assert_eq!(thread.len(), 1);
        assert!(thread.get(&id).is_some());
    }

    #[test]
    fn test_reply_chain() {
        let mut thread = MessageThread::new();

        let msg1 = create_message("Original");
        let msg1_id = msg1.message_id.clone();
        thread.add(msg1);

        let msg1_ref = thread.get(&msg1_id).unwrap();
        let msg2 = msg1_ref.reply(
            Address::agent("other"),
            MessageBody::new("Reply".to_string()),
        );
        let msg2_id = msg2.message_id.clone();
        thread.add(msg2);

        // Check parent-child relationship
        let msg2_ref = thread.get(&msg2_id).unwrap();
        assert_eq!(msg2_ref.in_reply_to, Some(msg1_id.clone()));

        let children: Vec<_> = thread.children_of(&msg1_id).collect();
        assert_eq!(children.len(), 1);
        assert_eq!(children[0].message_id, msg2_id);
    }

    #[test]
    fn test_thread_depth() {
        let mut thread = MessageThread::new();

        let msg1 = create_message("Level 0");
        thread.add(msg1);

        // Create a chain of replies
        let messages: Vec<_> = thread.roots().collect();
        let msg1_ref = messages[0];
        let msg2 = msg1_ref.reply(Address::agent("a"), MessageBody::new("Level 1".to_string()));
        thread.add(msg2);

        let messages: Vec<_> = thread.messages.values().collect();
        let msg2_ref = messages.iter().find(|m| m.subject == "Re: Level 0").unwrap();
        let msg3 = msg2_ref.reply(Address::agent("b"), MessageBody::new("Level 2".to_string()));
        thread.add(msg3);

        let stats = thread.stats();
        assert_eq!(stats.total_messages, 3);
        assert_eq!(stats.root_messages, 1);
        assert_eq!(stats.max_depth, 2);
    }

    #[test]
    fn test_chronological_order() {
        let mut thread = MessageThread::new();

        // Add messages in non-chronological order
        let mut msg1 = create_message("First");
        msg1.date = chrono::Utc::now() - chrono::Duration::hours(2);
        thread.add(msg1);

        let mut msg2 = create_message("Second");
        msg2.date = chrono::Utc::now() - chrono::Duration::hours(1);
        thread.add(msg2);

        let mut msg3 = create_message("Third");
        msg3.date = chrono::Utc::now();
        thread.add(msg3);

        let chronological: Vec<_> = thread.chronological();
        assert_eq!(chronological[0].subject, "First");
        assert_eq!(chronological[1].subject, "Second");
        assert_eq!(chronological[2].subject, "Third");
    }
}
