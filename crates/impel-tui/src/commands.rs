//! Command parsing and execution

use impel_core::coordination::{Command, CoordinationState};
use impel_core::error::Result;
use impel_core::thread::ThreadId;

/// Parse and execute a command string
pub fn execute_command(input: &str, state: &mut CoordinationState) -> CommandResult {
    let parts: Vec<&str> = input.split_whitespace().collect();
    if parts.is_empty() {
        return CommandResult::Error("Empty command".to_string());
    }

    match parts[0] {
        "spawn" => {
            let title = parts[1..].join(" ");
            if title.is_empty() {
                return CommandResult::Error("Usage: spawn <title>".to_string());
            }

            let cmd = Command::CreateThread {
                title: title.clone(),
                description: String::new(),
                parent_id: None,
                priority: None,
            };

            match cmd.execute(state) {
                Ok(events) => {
                    let thread_id = &events[0].entity_id;
                    CommandResult::Success(format!("Created thread: {}", thread_id))
                }
                Err(e) => CommandResult::Error(e.to_string()),
            }
        }

        "kill" => {
            if parts.len() < 2 {
                return CommandResult::Error("Usage: kill <thread-id>".to_string());
            }

            match ThreadId::parse(parts[1]) {
                Ok(thread_id) => {
                    let cmd = Command::KillThread {
                        thread_id,
                        reason: parts.get(2..).map(|r| r.join(" ")),
                    };
                    match cmd.execute(state) {
                        Ok(_) => CommandResult::Success("Thread killed".to_string()),
                        Err(e) => CommandResult::Error(e.to_string()),
                    }
                }
                Err(e) => CommandResult::Error(format!("Invalid thread ID: {}", e)),
            }
        }

        "merge" => {
            if parts.len() < 3 {
                return CommandResult::Error("Usage: merge <source-id> <target-id>".to_string());
            }

            match (ThreadId::parse(parts[1]), ThreadId::parse(parts[2])) {
                (Ok(source_id), Ok(target_id)) => {
                    let cmd = Command::MergeThreads {
                        source_id,
                        target_id,
                    };
                    match cmd.execute(state) {
                        Ok(_) => CommandResult::Success("Threads merged".to_string()),
                        Err(e) => CommandResult::Error(e.to_string()),
                    }
                }
                _ => CommandResult::Error("Invalid thread IDs".to_string()),
            }
        }

        "priority" => {
            if parts.len() < 3 {
                return CommandResult::Error("Usage: priority <thread-id> <0.0-1.0>".to_string());
            }

            match (ThreadId::parse(parts[1]), parts[2].parse::<f64>()) {
                (Ok(thread_id), Ok(temp)) => {
                    let cmd = Command::SetTemperature {
                        thread_id,
                        temperature: temp,
                        reason: "Manual adjustment".to_string(),
                    };
                    match cmd.execute(state) {
                        Ok(_) => CommandResult::Success(format!("Temperature set to {:.2}", temp)),
                        Err(e) => CommandResult::Error(e.to_string()),
                    }
                }
                _ => CommandResult::Error("Invalid arguments".to_string()),
            }
        }

        "ack" => {
            if parts.len() < 2 {
                return CommandResult::Error("Usage: ack <escalation-id>".to_string());
            }

            let cmd = Command::AcknowledgeEscalation {
                escalation_id: parts[1].to_string(),
                by: "human".to_string(),
            };
            match cmd.execute(state) {
                Ok(_) => CommandResult::Success("Escalation acknowledged".to_string()),
                Err(e) => CommandResult::Error(e.to_string()),
            }
        }

        "pause" => {
            let cmd = Command::PauseSystem {
                reason: parts.get(1..).map(|r| r.join(" ")),
            };
            match cmd.execute(state) {
                Ok(_) => CommandResult::Success("System paused".to_string()),
                Err(e) => CommandResult::Error(e.to_string()),
            }
        }

        "resume" => {
            let cmd = Command::ResumeSystem;
            match cmd.execute(state) {
                Ok(_) => CommandResult::Success("System resumed".to_string()),
                Err(e) => CommandResult::Error(e.to_string()),
            }
        }

        _ => CommandResult::Error(format!("Unknown command: {}", parts[0])),
    }
}

/// Result of command execution
#[derive(Debug)]
pub enum CommandResult {
    Success(String),
    Error(String),
}
