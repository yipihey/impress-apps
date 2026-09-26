//! What a build may execute — LaTeX engines, BibTeX, a figure script —
//! through a host the caller supplies (ADR-0030 D6). The engine never
//! spawns on its own: `imprint-service` hands it a [`ProcessRunnerHost`],
//! tests a [`ScriptedRunnerHost`], and a GUI can hand it one that asks
//! first. Every run is bounded by a timeout and comes back with what it
//! printed, so a build report can show the researcher exactly what ran.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// One process to run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunRequest {
    /// A program name (searched) or an absolute path.
    pub program: String,
    pub args: Vec<String>,
    pub cwd: PathBuf,
    pub env: Vec<(String, String)>,
    pub timeout: Duration,
}

impl RunRequest {
    pub fn new(program: impl Into<String>, cwd: impl Into<PathBuf>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            cwd: cwd.into(),
            env: Vec::new(),
            timeout: DEFAULT_TIMEOUT,
        }
    }

    pub fn arg(mut self, a: impl Into<String>) -> Self {
        self.args.push(a.into());
        self
    }

    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// The command line as a person would type it (for logs and reports).
    pub fn display(&self) -> String {
        let mut s = self.program.clone();
        for a in &self.args {
            s.push(' ');
            if a.contains(' ') {
                s.push('"');
                s.push_str(a);
                s.push('"');
            } else {
                s.push_str(a);
            }
        }
        s
    }
}

/// Ten minutes: a full LaTeX document with bibliography passes, or a figure
/// script that fits a model, without an interactive process ever hanging a
/// build forever.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(600);

/// What a process did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RunOutput {
    /// The exit code; `None` when killed (timeout, cancel or signal).
    pub status: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub duration_ms: u64,
    pub timed_out: bool,
    /// Killed because the host's cancel flag was raised (ADR-0034 D6) —
    /// the person or agent asked the build to stop, not a hang.
    pub cancelled: bool,
}

impl RunOutput {
    pub fn ok(&self) -> bool {
        self.status == Some(0) && !self.timed_out && !self.cancelled
    }

    /// The tail of what it printed, for a one-line report.
    pub fn summary(&self) -> String {
        let text = if self.stderr.trim().is_empty() {
            &self.stdout
        } else {
            &self.stderr
        };
        let last = text.lines().rev().find(|l| !l.trim().is_empty());
        match (self.cancelled, self.timed_out, self.status, last) {
            (true, _, _, _) => "cancelled".to_string(),
            (false, true, _, _) => "timed out".to_string(),
            (false, false, Some(0), _) => "ok".to_string(),
            (false, false, code, Some(line)) => format!("exit {:?}: {}", code, line.trim()),
            (false, false, code, None) => format!("exit {code:?}"),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum RunError {
    #[error("{program}: not found (searched {searched})")]
    NotFound { program: String, searched: String },
    #[error("{program}: {source}")]
    Spawn {
        program: String,
        #[source]
        source: std::io::Error,
    },
}

/// The port: something that can find and run programs — and, since the
/// build is a job (ADR-0034 D6), the seam through which it reports each
/// step and learns it should stop. The three hooks default to nothing, so
/// a host that only runs programs is unchanged.
pub trait RunnerHost: Send + Sync {
    /// Where `program` is, if this host can run it.
    fn which(&self, program: &str) -> Option<PathBuf>;
    fn run(&self, request: &RunRequest) -> Result<RunOutput, RunError>;

    /// Has the caller asked the build to stop? `build` asks before each
    /// step and before the document engine; a process host also asks in
    /// its wait loop and kills the child.
    fn cancel_requested(&self) -> bool {
        false
    }

    /// A figure step is about to run (its source path and runner name).
    fn step_started(&self, _source: &str, _runner: &str) {}

    /// A figure step finished, however it finished.
    fn step_finished(&self, _report: &super::build::StepReport) {}
}

/// A host over another host that forwards the three job hooks to
/// closures — what `imprint-service` wraps a [`ProcessRunnerHost`] in to
/// stream a build's steps into the job's event ring.
pub struct ObservedHost<H: RunnerHost> {
    inner: H,
    on_step_started: StepStartedHook,
    on_step_finished: StepFinishedHook,
    cancel: CancelHook,
}

type StepStartedHook = Box<dyn Fn(&str, &str) + Send + Sync>;
type StepFinishedHook = Box<dyn Fn(&super::build::StepReport) + Send + Sync>;
type CancelHook = Box<dyn Fn() -> bool + Send + Sync>;

impl<H: RunnerHost> ObservedHost<H> {
    pub fn new(
        inner: H,
        on_step_started: impl Fn(&str, &str) + Send + Sync + 'static,
        on_step_finished: impl Fn(&super::build::StepReport) + Send + Sync + 'static,
        cancel: impl Fn() -> bool + Send + Sync + 'static,
    ) -> Self {
        Self {
            inner,
            on_step_started: Box::new(on_step_started),
            on_step_finished: Box::new(on_step_finished),
            cancel: Box::new(cancel),
        }
    }
}

impl<H: RunnerHost> RunnerHost for ObservedHost<H> {
    fn which(&self, program: &str) -> Option<PathBuf> {
        self.inner.which(program)
    }

    fn run(&self, request: &RunRequest) -> Result<RunOutput, RunError> {
        self.inner.run(request)
    }

    fn cancel_requested(&self) -> bool {
        (self.cancel)() || self.inner.cancel_requested()
    }

    fn step_started(&self, source: &str, runner: &str) {
        (self.on_step_started)(source, runner);
    }

    fn step_finished(&self, report: &super::build::StepReport) {
        (self.on_step_finished)(report);
    }
}

/// Directories a GUI app's `PATH` lacks but a researcher's shell has:
/// TeX Live's `texbin`, Homebrew, MacPorts, the user's own bins.
pub const WELL_KNOWN_DIRS: &[&str] = &[
    "/Library/TeX/texbin",
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/opt/local/bin",
    "/usr/bin",
    "/bin",
];

/// Runs real processes with `std::process`, output captured on threads,
/// killed at the timeout.
pub struct ProcessRunnerHost {
    search: Vec<PathBuf>,
    /// Raised by the job runner when a cancel is requested; the wait loop
    /// kills the child within one poll (25 ms) of it going up.
    cancel: Option<Arc<AtomicBool>>,
}

impl Default for ProcessRunnerHost {
    fn default() -> Self {
        Self::new()
    }
}

impl ProcessRunnerHost {
    /// `PATH` first, then the well-known directories, then `~/.cargo/bin`
    /// and `~/.local/bin`.
    pub fn new() -> Self {
        let mut search: Vec<PathBuf> = std::env::var_os("PATH")
            .map(|p| std::env::split_paths(&p).collect())
            .unwrap_or_default();
        for d in WELL_KNOWN_DIRS {
            search.push(PathBuf::from(d));
        }
        if let Some(home) = dirs::home_dir() {
            search.push(home.join(".cargo/bin"));
            search.push(home.join(".local/bin"));
        }
        search.dedup();
        Self {
            search,
            cancel: None,
        }
    }

    pub fn with_search(search: Vec<PathBuf>) -> Self {
        Self {
            search,
            cancel: None,
        }
    }

    /// Kill whatever runs when `flag` goes up, and answer
    /// `cancel_requested` from it.
    pub fn with_cancel(mut self, flag: Arc<AtomicBool>) -> Self {
        self.cancel = Some(flag);
        self
    }

    fn cancel_raised(&self) -> bool {
        self.cancel
            .as_ref()
            .is_some_and(|f| f.load(Ordering::Relaxed))
    }

    fn path_env(&self) -> String {
        std::env::join_paths(&self.search)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default()
    }
}

/// Kill `child` and every process in its group (it was spawned as the
/// group leader), then reap it. `/bin/kill` with a negative pid is the
/// portable spelling of `killpg` that needs neither `libc` nor `unsafe`;
/// the direct `kill()` after it covers a `kill` binary that is missing.
fn kill_group(child: &mut std::process::Child) {
    let group = format!("-{}", child.id());
    let _ = Command::new("kill")
        .args(["-9", "--", &group])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = child.kill();
    let _ = child.wait();
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.is_file()
        && std::fs::metadata(path)
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
}

impl RunnerHost for ProcessRunnerHost {
    fn which(&self, program: &str) -> Option<PathBuf> {
        if program.contains('/') {
            let p = PathBuf::from(program);
            return is_executable(&p).then_some(p);
        }
        self.search
            .iter()
            .map(|d| d.join(program))
            .find(|p| is_executable(p))
    }

    fn run(&self, request: &RunRequest) -> Result<RunOutput, RunError> {
        let program = self
            .which(&request.program)
            .ok_or_else(|| RunError::NotFound {
                program: request.program.clone(),
                searched: self.path_env(),
            })?;
        let mut cmd = Command::new(&program);
        cmd.args(&request.args)
            .current_dir(&request.cwd)
            .env("PATH", self.path_env())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            // Its own process group, so a kill reaches what it forked. A
            // `sh -c` step's real work is a grandchild; killing only the
            // shell left the grandchild holding the stdout/stderr pipes,
            // and the reader threads waited for it — a cancelled 45 s step
            // still took 45 s (P4's live proof), and a timed-out one would
            // have too.
            .process_group(0);
        for (k, v) in &request.env {
            cmd.env(k, v);
        }
        let start = Instant::now();
        let mut child = cmd.spawn().map_err(|e| RunError::Spawn {
            program: request.program.clone(),
            source: e,
        })?;
        let mut stdout = child.stdout.take();
        let mut stderr = child.stderr.take();
        let out_thread = std::thread::spawn(move || {
            let mut buf = Vec::new();
            if let Some(s) = stdout.as_mut() {
                let _ = s.read_to_end(&mut buf);
            }
            buf
        });
        let err_thread = std::thread::spawn(move || {
            let mut buf = Vec::new();
            if let Some(s) = stderr.as_mut() {
                let _ = s.read_to_end(&mut buf);
            }
            buf
        });
        let mut timed_out = false;
        let mut cancelled = false;
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status.code(),
                Ok(None) => {
                    if self.cancel_raised() {
                        kill_group(&mut child);
                        cancelled = true;
                        break None;
                    }
                    if start.elapsed() >= request.timeout {
                        kill_group(&mut child);
                        timed_out = true;
                        break None;
                    }
                    std::thread::sleep(Duration::from_millis(25));
                }
                Err(e) => {
                    return Err(RunError::Spawn {
                        program: request.program.clone(),
                        source: e,
                    })
                }
            }
        };
        let stdout = String::from_utf8_lossy(&out_thread.join().unwrap_or_default()).into_owned();
        let stderr = String::from_utf8_lossy(&err_thread.join().unwrap_or_default()).into_owned();
        Ok(RunOutput {
            status,
            stdout,
            stderr,
            duration_ms: start.elapsed().as_millis() as u64,
            timed_out,
            cancelled,
        })
    }

    fn cancel_requested(&self) -> bool {
        self.cancel_raised()
    }
}

/// A host for tests: says which programs exist, answers each run through a
/// closure, and records every request so a test can assert what a build
/// would have executed.
pub struct ScriptedRunnerHost {
    available: Vec<String>,
    handler: Box<dyn Fn(&RunRequest) -> RunOutput + Send + Sync>,
    calls: Mutex<Vec<RunRequest>>,
}

impl ScriptedRunnerHost {
    pub fn new<F>(available: &[&str], handler: F) -> Self
    where
        F: Fn(&RunRequest) -> RunOutput + Send + Sync + 'static,
    {
        Self {
            available: available.iter().map(|s| s.to_string()).collect(),
            handler: Box::new(handler),
            calls: Mutex::new(Vec::new()),
        }
    }

    /// A host with nothing installed.
    pub fn empty() -> Self {
        Self::new(&[], |_| RunOutput::default())
    }

    pub fn calls(&self) -> Vec<RunRequest> {
        self.calls.lock().map(|c| c.clone()).unwrap_or_default()
    }

    /// A successful run that printed nothing.
    pub fn success() -> RunOutput {
        RunOutput {
            status: Some(0),
            ..Default::default()
        }
    }
}

impl RunnerHost for ScriptedRunnerHost {
    fn which(&self, program: &str) -> Option<PathBuf> {
        self.available
            .iter()
            .any(|p| p == program)
            .then(|| PathBuf::from(format!("/scripted/{program}")))
    }

    fn run(&self, request: &RunRequest) -> Result<RunOutput, RunError> {
        if self.which(&request.program).is_none() {
            return Err(RunError::NotFound {
                program: request.program.clone(),
                searched: "scripted host".into(),
            });
        }
        if let Ok(mut calls) = self.calls.lock() {
            calls.push(request.clone());
        }
        Ok((self.handler)(request))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_real_process_runs_with_captured_output_and_a_timeout() {
        let host = ProcessRunnerHost::new();
        let dir = std::env::temp_dir();
        let out = host
            .run(&RunRequest::new("sh", &dir).args(["-c", "echo hi; echo oops >&2; exit 3"]))
            .unwrap();
        assert_eq!(out.status, Some(3));
        assert_eq!(out.stdout.trim(), "hi");
        assert_eq!(out.stderr.trim(), "oops");
        assert!(!out.ok());
        assert!(out.summary().contains("oops"));

        let slow = host
            .run(
                &RunRequest::new("sh", &dir)
                    .args(["-c", "sleep 5"])
                    .timeout(Duration::from_millis(200)),
            )
            .unwrap();
        assert!(slow.timed_out);
        assert_eq!(slow.summary(), "timed out");

        let missing = host.run(&RunRequest::new("no-such-program-xyz", &dir));
        assert!(matches!(missing, Err(RunError::NotFound { .. })));
    }

    /// ADR-0034 D6: a raised cancel flag kills the running child within a
    /// poll, and the output says `cancelled` — not `timed out`. The step
    /// is a shell whose real work is a GRANDCHILD holding the output
    /// pipes: the whole group dies, or `run` would sit in the reader
    /// threads until the grandchild's own sleep ended (P4's live proof
    /// found exactly that: a cancelled 45 s step took 45 s).
    #[test]
    fn a_raised_cancel_flag_kills_the_child_and_its_group() {
        let flag = Arc::new(AtomicBool::new(false));
        let host = ProcessRunnerHost::new().with_cancel(flag.clone());
        let raiser = {
            let flag = flag.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(300));
                flag.store(true, Ordering::Relaxed);
            })
        };
        let start = Instant::now();
        let out = host
            .run(
                &RunRequest::new("sh", std::env::temp_dir())
                    .args(["-c", "sh -c 'sleep 20'; echo after"])
                    .timeout(Duration::from_secs(60)),
            )
            .unwrap();
        raiser.join().unwrap();
        assert!(out.cancelled, "{out:?}");
        assert!(!out.timed_out);
        assert!(!out.ok());
        assert_eq!(out.summary(), "cancelled");
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "the grandchild kept the pipes open: {:?}",
            start.elapsed()
        );
        assert!(host.cancel_requested());
    }

    /// The timeout path kills the group too.
    #[test]
    fn a_timed_out_step_does_not_wait_for_its_grandchild() {
        let host = ProcessRunnerHost::new();
        let start = Instant::now();
        let out = host
            .run(
                &RunRequest::new("sh", std::env::temp_dir())
                    .args(["-c", "sh -c 'sleep 20'"])
                    .timeout(Duration::from_millis(300)),
            )
            .unwrap();
        assert!(out.timed_out);
        assert!(start.elapsed() < Duration::from_secs(5), "{:?}", start.elapsed());
    }

    #[test]
    fn the_scripted_host_records_what_a_build_asked_for() {
        let host = ScriptedRunnerHost::new(&["pdflatex"], |req| RunOutput {
            status: Some(0),
            stdout: format!("ran {}", req.display()),
            ..Default::default()
        });
        let out = host
            .run(&RunRequest::new("pdflatex", "/tmp").arg("main.tex"))
            .unwrap();
        assert!(out.ok());
        assert_eq!(out.stdout, "ran pdflatex main.tex");
        assert_eq!(host.calls().len(), 1);
        assert!(host.run(&RunRequest::new("bibtex", "/tmp")).is_err());
    }
}
