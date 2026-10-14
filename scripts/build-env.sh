# shellcheck shell=bash
# Where builds go, and the guard that stops them starting on a full disk.
# Sourced by every crates/*/build-xcframework.sh and scripts/build-impress-app.sh.
#
# WHY. By 2026-10-14 this repo's builds held ~3.2 TB: 111 private
# `target-<task>` dirs in agent worktrees (947 GB), 33 per-job CI target dirs
# (1.3 TB), and worktrees nobody removed. Each new dir is a cold build of ~900
# crates, so the same habit that filled the disk also made every build slow.
# docs/plan-build-storage.md has the measurements.
#
# THE RULE. Two Cargo target dirs per machine, never more:
#   * the main checkout builds into its own `target/` — its target/release
#     holds the signed impress-mcp, vw-mcp and impress binaries that are
#     running, so no branch build may overwrite them;
#   * every worktree under .claude/worktrees/ builds into ONE shared
#     `.claude/target-worktrees`, set by the untracked cargo config that
#     impress_install_worktree_cargo_config writes. Cargo reads config from
#     every ancestor directory, so it applies to plain `cargo test` and
#     rust-analyzer too, not only to these scripts.
# Parallel worktree builds queue on Cargo's build lock. That is the trade:
# a wait on a warm dir instead of a cold build in a new one. Never set
# CARGO_TARGET_DIR=$PWD/target-<task> to dodge the lock.

# The repository's main checkout, from any worktree.
impress_main_root() {   # [dir]
    local common
    common=$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    dirname "$common"
}

# The target dir cargo will really use here — ask cargo instead of guessing,
# so CARGO_TARGET_DIR, the worktree config and the default all agree.
impress_target_dir() {   # workspace_root
    local root="$1" dir
    dir=$(cd "$root" && cargo metadata --format-version 1 --no-deps 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null) || true
    echo "${dir:-${CARGO_TARGET_DIR:-$root/target}}"
}

# Write <main>/.claude/worktrees/.cargo/config.toml. Idempotent; untracked
# (.claude/ is gitignored), so build-impress-app.sh and the janitor re-assert it.
impress_install_worktree_cargo_config() {   # [dir]
    local main cfg want
    main=$(impress_main_root "${1:-.}") || return 0
    cfg="$main/.claude/worktrees/.cargo/config.toml"
    want='# Written by scripts/build-env.sh — see the rule there. Every worktree
# under this directory shares one target dir; the main checkout keeps target/.
[build]
target-dir = "../target-worktrees"'
    [ -f "$cfg" ] && [ "$(cat "$cfg")" = "$want" ] && return 0
    mkdir -p "$(dirname "$cfg")" && printf '%s\n' "$want" > "$cfg"
}

# Refuse to start a build that would run the disk out of space halfway.
impress_require_free_space() {   # [min_gb]
    local min="${1:-${IMPRESS_MIN_FREE_GB:-50}}" free_kb
    free_kb=$(df -k "${HOME}" | awk 'NR==2 {print $4}')
    if [ -n "$free_kb" ] && [ "$free_kb" -lt $((min * 1048576)) ]; then
        echo "error: only $((free_kb / 1048576)) GB free; builds need ${min} GB." >&2
        echo "       Run scripts/clean-build-data.sh (dry run) to see what can go." >&2
        return 1
    fi
}
