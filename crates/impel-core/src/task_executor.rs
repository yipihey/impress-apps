/// Trait for executing tasks via the impel agent system.
///
/// Implementors plug concrete execution logic into the impel orchestration
/// pipeline. The trait is intentionally synchronous at the boundary — callers
/// that need async execution should spawn a thread or use an async wrapper.
///
/// # Design note
///
/// This trait follows ADR-0005's guidance that cross-crate execution contracts
/// should be expressed as minimal traits rather than concrete types. `impel-core`
/// defines the contract; the Swift `NativeAgentLoop` and the Rust `impel-server`
/// both satisfy it through their respective adapters.
pub trait TaskExecutor: Send + Sync {
    /// Execute a task and return the result as a string.
    ///
    /// # Parameters
    ///
    /// - `task_id`: Stable UUID string identifying the task in the GRDB store.
    /// - `input`: The natural-language query or instruction to execute.
    ///
    /// # Returns
    ///
    /// The agent's textual response on success, or a boxed error on failure.
    fn execute(
        &self,
        task_id: &str,
        input: &str,
    ) -> Result<String, Box<dyn std::error::Error + Send + Sync>>;
}
