//! The task scheduler — ADR-0005 §6's execution loop (ADR-0015 D5), now
//! koine's (`koine_tasks::scheduler`, koine docs/plan-koine-ai-tasks.md Q-D1).
//! `impel-taskd` constructs it with `start_delay` ≥ 90 s (the app-launch
//! guard); `run_once` stays undelayed for tests and CLIs.

pub use koine_tasks::scheduler::*;
