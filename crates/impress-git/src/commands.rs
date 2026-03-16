use std::collections::HashMap;

use crate::models::GitCommand;

/// Default SSH command that disables interactive prompts.
const SSH_BATCH: &str = "ssh -o BatchMode=yes";

fn base_git_cmd() -> GitCommand {
    let mut env = HashMap::new();
    env.insert("GIT_SSH_COMMAND".into(), SSH_BATCH.into());
    // Disable interactive pagers
    env.insert("GIT_TERMINAL_PROMPT".into(), "0".into());
    GitCommand {
        executable: "git".into(),
        args: Vec::new(),
        env,
    }
}

/// `git clone <url> <target> [--branch <branch>]`
pub fn clone_cmd(url: &str, target: &str, branch: Option<&str>) -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.push("clone".into());
    if let Some(b) = branch {
        cmd.args.push("--branch".into());
        cmd.args.push(b.into());
    }
    cmd.args.push(url.into());
    cmd.args.push(target.into());
    cmd
}

/// `git status --porcelain=v2 --branch`
pub fn status_cmd() -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args
        .extend(["status", "--porcelain=v2", "--branch"].map(String::from));
    cmd
}

/// `git commit -m <message> [-- <paths...>]`
pub fn commit_cmd(message: &str, paths: &[&str]) -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.push("commit".into());
    cmd.args.push("-m".into());
    cmd.args.push(message.into());
    if !paths.is_empty() {
        cmd.args.push("--".into());
        cmd.args.extend(paths.iter().map(|p| (*p).into()));
    }
    cmd
}

/// `git push <remote> <branch>`
pub fn push_cmd(remote: &str, branch: &str) -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args
        .extend(["push", remote, branch].map(String::from));
    cmd
}

/// `git pull [--rebase] <remote> <branch>`
pub fn pull_cmd(remote: &str, branch: &str, rebase: bool) -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.push("pull".into());
    if rebase {
        cmd.args.push("--rebase".into());
    }
    cmd.args.push(remote.into());
    cmd.args.push(branch.into());
    cmd
}

/// `git fetch <remote>`
pub fn fetch_cmd(remote: &str) -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.extend(["fetch", remote].map(String::from));
    cmd
}

/// `git log --format=<format> -n <count>`
///
/// Format: `%H%x00%h%x00%s%x00%an%x00%ae%x00%aI%x00` (NUL-delimited fields, newline-delimited records)
pub fn log_cmd(count: u32) -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.push("log".into());
    cmd.args
        .push("--format=%H%x00%h%x00%s%x00%an%x00%ae%x00%aI".into());
    cmd.args.push(format!("-n{}", count));
    cmd
}

/// `git diff [--cached] [--numstat]`
pub fn diff_cmd(cached: bool) -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.push("diff".into());
    if cached {
        cmd.args.push("--cached".into());
    }
    cmd
}

/// `git diff --numstat [--cached]`
pub fn diff_stat_cmd(cached: bool) -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.push("diff".into());
    cmd.args.push("--numstat".into());
    if cached {
        cmd.args.push("--cached".into());
    }
    cmd
}

/// `git branch -a --format=<format>`
pub fn branch_list_cmd() -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.push("branch".into());
    cmd.args.push("-a".into());
    cmd.args
        .push("--format=%(HEAD)%x00%(refname:short)%x00%(upstream:short)%x00%(refname:rstrip=-2)".into());
    cmd
}

/// `git checkout <branch>`
pub fn checkout_cmd(branch: &str) -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.extend(["checkout", branch].map(String::from));
    cmd
}

/// `git stash`
pub fn stash_cmd() -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.push("stash".into());
    cmd
}

/// `git stash pop`
pub fn stash_pop_cmd() -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.extend(["stash", "pop"].map(String::from));
    cmd
}

/// `git init`
pub fn init_cmd() -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.push("init".into());
    cmd
}

/// `git remote add <name> <url>`
pub fn remote_add_cmd(name: &str, url: &str) -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args
        .extend(["remote", "add", name, url].map(String::from));
    cmd
}

/// `git remote -v`
pub fn remote_list_cmd() -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.extend(["remote", "-v"].map(String::from));
    cmd
}

/// `git add <paths...>`
pub fn add_cmd(paths: &[&str]) -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.push("add".into());
    cmd.args.extend(paths.iter().map(|p| (*p).into()));
    cmd
}

/// `git rev-parse HEAD`
pub fn rev_parse_head_cmd() -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.extend(["rev-parse", "HEAD"].map(String::from));
    cmd
}

/// `git rev-parse --abbrev-ref HEAD`
pub fn current_branch_cmd() -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args
        .extend(["rev-parse", "--abbrev-ref", "HEAD"].map(String::from));
    cmd
}

/// `git --version`
pub fn version_cmd() -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args.push("--version".into());
    cmd
}

/// `git config user.name`
pub fn config_user_name_cmd() -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args
        .extend(["config", "user.name"].map(String::from));
    cmd
}

/// `git config user.email`
pub fn config_user_email_cmd() -> GitCommand {
    let mut cmd = base_git_cmd();
    cmd.args
        .extend(["config", "user.email"].map(String::from));
    cmd
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clone_cmd_basic() {
        let cmd = clone_cmd("git@github.com:user/repo.git", "/tmp/repo", None);
        assert_eq!(cmd.args, vec!["clone", "git@github.com:user/repo.git", "/tmp/repo"]);
        assert_eq!(cmd.env.get("GIT_SSH_COMMAND").unwrap(), SSH_BATCH);
    }

    #[test]
    fn clone_cmd_with_branch() {
        let cmd = clone_cmd("https://github.com/user/repo.git", "/tmp/repo", Some("develop"));
        assert_eq!(
            cmd.args,
            vec!["clone", "--branch", "develop", "https://github.com/user/repo.git", "/tmp/repo"]
        );
    }

    #[test]
    fn status_cmd_porcelain() {
        let cmd = status_cmd();
        assert_eq!(cmd.args, vec!["status", "--porcelain=v2", "--branch"]);
    }

    #[test]
    fn commit_cmd_with_paths() {
        let cmd = commit_cmd("fix typo", &["main.tex", "refs.bib"]);
        assert_eq!(
            cmd.args,
            vec!["commit", "-m", "fix typo", "--", "main.tex", "refs.bib"]
        );
    }

    #[test]
    fn commit_cmd_no_paths() {
        let cmd = commit_cmd("initial commit", &[]);
        assert_eq!(cmd.args, vec!["commit", "-m", "initial commit"]);
    }

    #[test]
    fn pull_with_rebase() {
        let cmd = pull_cmd("origin", "main", true);
        assert_eq!(cmd.args, vec!["pull", "--rebase", "origin", "main"]);
    }

    #[test]
    fn pull_without_rebase() {
        let cmd = pull_cmd("origin", "main", false);
        assert_eq!(cmd.args, vec!["pull", "origin", "main"]);
    }

    #[test]
    fn diff_stat_cached() {
        let cmd = diff_stat_cmd(true);
        assert_eq!(cmd.args, vec!["diff", "--numstat", "--cached"]);
    }

    #[test]
    fn add_multiple_paths() {
        let cmd = add_cmd(&["src/main.tex", "figures/"]);
        assert_eq!(cmd.args, vec!["add", "src/main.tex", "figures/"]);
    }
}
