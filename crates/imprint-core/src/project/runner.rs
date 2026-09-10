//! What a build may execute — LaTeX engines, BibTeX, a figure script —
//! through a host the caller supplies (ADR-0030 D6). The engine never
//! spawns on its own: `imprint-service` hands it a [`ProcessRunnerHost`],
//! tests a [`ScriptedRunnerHost`], and a GUI can hand it one that asks
//! first. Every run is bounded by a timeout and comes back with what it
//! printed, so a build report can show the researcher exactly what ran.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
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
    /// The exit code; `None` when killed (timeout or signal).
    pub status: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub duration_ms: u64,
    pub timed_out: bool,
}

impl RunOutput {
    pub fn ok(&self) -> bool {
        self.status == Some(0) && !self.timed_out
    }

    /// The tail of what it printed, for a one-line report.
    pub fn summary(&self) -> String {
        let text = if self.stderr.trim().is_empty() {
            &self.stdout
        } else {
            &self.stderr
        };
        let last = text.lines().rev().find(|l| !l.trim().is_empty());
        match (self.timed_out, self.status, last) {
            (true, _, _) => "timed out".to_string(),
            (false, Some(0), _) => "ok".to_string(),
            (false, code, Some(line)) => format!("exit {:?}: {}", code, line.trim()),
            (false, code, None) => format!("exit {code:?}"),
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

/// The port: something that can find and run programs.
pub trait RunnerHost: Send + Sync {
    /// Where `program` is, if this host can run it.
    fn which(&self, program: &str) -> Option<PathBuf>;
    fn run(&self, request: &RunRequest) -> Result<RunOutput, RunError>;
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
        Self { search }
    }

    pub fn with_search(search: Vec<PathBuf>) -> Self {
        Self { search }
    }

    fn path_env(&self) -> String {
        std::env::join_paths(&self.search)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default()
    }
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
            .stderr(Stdio::piped());
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
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status.code(),
                Ok(None) => {
                    if start.elapsed() >= request.timeout {
                        let _ = child.kill();
                        let _ = child.wait();
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
        })
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
