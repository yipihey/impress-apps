//! IMAP client implementation.

use crate::{ImpartError, Result};
use crate::types::{Address, Envelope, Mailbox};
use crate::mime::ParsedMessage;
use imap::{ClientBuilder, Session};
use std::borrow::Cow;

// MARK: - IMAP Client

/// IMAP client for fetching messages.
pub struct ImapClient {
    session: Session<imap::Connection>,
}

impl ImapClient {
    /// Create a new IMAP connection.
    pub fn new(config: &crate::types::AccountConfig, password: &str) -> Result<Self> {
        let client = ClientBuilder::new(&config.imap_host, config.imap_port)
            .connect()
            .map_err(|e| ImpartError::Network(e.to_string()))?;

        let session = client
            .login(&config.email, password)
            .map_err(|e| ImpartError::Auth(e.0.to_string()))?;

        Ok(Self { session })
    }

    /// List all mailboxes.
    pub fn list_mailboxes(&mut self) -> Result<Vec<Mailbox>> {
        let mailboxes = self
            .session
            .list(None, Some("*"))
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        Ok(mailboxes
            .iter()
            .map(|m| Mailbox {
                name: m.name().to_string(),
                delimiter: m.delimiter().map(|d| d.to_string()).unwrap_or_else(|| "/".to_string()),
                flags: m.attributes().iter().map(|a| format!("{:?}", a)).collect(),
                message_count: 0,
                unseen_count: 0,
            })
            .collect())
    }

    /// Fetch message envelopes from a mailbox.
    pub fn fetch_envelopes(
        &mut self,
        mailbox_name: &str,
        _start: u32,
        count: u32,
    ) -> Result<Vec<Envelope>> {
        let mailbox = self.session
            .select(mailbox_name)
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let exists = mailbox.exists;
        if exists == 0 {
            return Ok(Vec::new());
        }

        // Calculate range (IMAP uses 1-based sequence numbers)
        let end = exists;
        let start_seq = if exists > count { exists - count + 1 } else { 1 };

        if start_seq > end {
            return Ok(Vec::new());
        }

        let range = format!("{}:{}", start_seq, end);
        let messages = self
            .session
            .fetch(&range, "(UID ENVELOPE FLAGS)")
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let mut envelopes = Vec::new();
        for msg in messages.iter() {
            if let Some(env) = msg.envelope() {
                envelopes.push(convert_envelope(msg.uid.unwrap_or(0), env, &msg.flags()));
            }
        }

        Ok(envelopes)
    }

    /// Fetch full message by UID.
    pub fn fetch_message(&mut self, mailbox_name: &str, uid: u32) -> Result<ParsedMessage> {
        self.session
            .select(mailbox_name)
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let messages = self
            .session
            .uid_fetch(uid.to_string(), "BODY[]")
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let msg = messages
            .iter()
            .next()
            .ok_or_else(|| ImpartError::Imap("Message not found".to_string()))?;

        let body = msg
            .body()
            .ok_or_else(|| ImpartError::Imap("No body".to_string()))?;

        crate::mime::parse_message(body)
    }

    /// Set flags on messages.
    pub fn set_flags(
        &mut self,
        mailbox_name: &str,
        uids: &[u32],
        flags: &[String],
        add: bool,
    ) -> Result<()> {
        self.session
            .select(mailbox_name)
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let uid_str = uids.iter().map(|u| u.to_string()).collect::<Vec<_>>().join(",");
        let flag_str = flags.join(" ");

        let query = if add {
            format!("+FLAGS ({})", flag_str)
        } else {
            format!("-FLAGS ({})", flag_str)
        };

        self.session
            .uid_store(&uid_str, &query)
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        Ok(())
    }

    /// Move messages to another mailbox.
    pub fn move_messages(
        &mut self,
        from_mailbox: &str,
        to_mailbox: &str,
        uids: &[u32],
    ) -> Result<()> {
        self.session
            .select(from_mailbox)
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let uid_str = uids.iter().map(|u| u.to_string()).collect::<Vec<_>>().join(",");

        self.session
            .uid_mv(&uid_str, to_mailbox)
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        Ok(())
    }

    /// Disconnect from server.
    pub fn disconnect(&mut self) {
        let _ = self.session.logout();
    }
}

/// Convert imap-proto envelope to our Envelope type.
fn convert_envelope(uid: u32, env: &imap_proto::Envelope, flags: &[imap::types::Flag]) -> Envelope {
    fn cow_to_string(cow: &Option<Cow<[u8]>>) -> Option<String> {
        cow.as_ref().map(|c| String::from_utf8_lossy(c).to_string())
    }

    fn convert_addresses(addrs: Option<&Vec<imap_proto::Address>>) -> Vec<Address> {
        addrs
            .map(|a| {
                a.iter()
                    .map(|addr| Address {
                        name: cow_to_string(&addr.name),
                        email: format!(
                            "{}@{}",
                            addr.mailbox.as_ref().map(|m| String::from_utf8_lossy(m)).unwrap_or_default(),
                            addr.host.as_ref().map(|h| String::from_utf8_lossy(h)).unwrap_or_default()
                        ),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    Envelope {
        uid,
        message_id: cow_to_string(&env.message_id),
        in_reply_to: cow_to_string(&env.in_reply_to),
        references: Vec::new(), // ENVELOPE doesn't include References, need BODY[HEADER]
        subject: cow_to_string(&env.subject),
        from: convert_addresses(env.from.as_ref()),
        to: convert_addresses(env.to.as_ref()),
        cc: convert_addresses(env.cc.as_ref()),
        bcc: convert_addresses(env.bcc.as_ref()),
        date: None, // Parse from date string if needed
        flags: flags.iter().map(|f| format!("{:?}", f)).collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cow_to_string() {
        let cow: Option<Cow<[u8]>> = Some(Cow::Borrowed(b"test"));
        let result = cow.as_ref().map(|c| String::from_utf8_lossy(c).to_string());
        assert_eq!(result, Some("test".to_string()));
    }
}
