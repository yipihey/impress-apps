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
# 50 GB on a workstation; 10 GB under CI, where GitHub-hosted macOS runners
# start with ~37 GB free and a framework build fits comfortably in that.
impress_require_free_space() {   # [min_gb]
    local default=50 free_kb min
    [ -n "${GITHUB_ACTIONS:-}" ] && default=10
    min="${1:-${IMPRESS_MIN_FREE_GB:-$default}}"
    free_kb=$(df -k "${HOME}" | awk 'NR==2 {print $4}')
    if [ -n "$free_kb" ] && [ "$free_kb" -lt $((min * 1048576)) ]; then
        echo "error: only $((free_kb / 1048576)) GB free; builds need ${min} GB." >&2
        echo "       Run scripts/clean-build-data.sh (dry run) to see what can go." >&2
        return 1
    fi
}

# --- framework publish stamp -------------------------------------------------
# Repackaging a framework whose archives did not change costs ~3 s a crate —
# a uniffi-bindgen pass, lipo, create-xcframework and the app-side copies — so
# an edit that touched one crate paid ~25 s for the seven it did not
# (measured 2026-10-14, docs/plan-build-storage.md § Dev loop). Each crate
# script records what it published in frameworks/.impress-stamp, and skips
# packaging when the archives cargo just produced are the same ones.
#
# "Same" is decided by size+mtime first and, only when those moved, by
# content: cargo relinks an archive whenever an input's mtime changes, and a
# touched-but-identical source produces a byte-identical archive.
# IMPRESS_FORCE_FRAMEWORKS=1 repackages regardless.

_impress_framework_stamp_tool() {   # mode framework_dir build_dir lib_name script
    python3 - "$@" <<'PY'
import glob, hashlib, json, os, sys
mode, fw, build, lib, script = sys.argv[1:6]
stamp = os.path.join(fw, ".impress-stamp")
flags = {k: os.environ.get(k, "") for k in
         ("IMPRESS_SKIP_X86", "IMPRESS_SKIP_IOS", "IMPRINT_SKIP_IOS", "IMPRINT_TECTONIC")}
def digest(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 22), b""):
            h.update(block)
    return h.hexdigest()
with open(script, "rb") as f:
    script_sum = hashlib.md5(f.read()).hexdigest()
libs = {}
for p in sorted(glob.glob(os.path.join(build, "*", "release", "lib%s.a" % lib))):
    st = os.stat(p)
    libs[p] = {"size": st.st_size, "mtime": st.st_mtime_ns}
def write(entries):
    tmp = stamp + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"flags": flags, "script": script_sum, "libs": entries}, f, indent=1)
    os.replace(tmp, stamp)
if mode == "write":
    write({p: dict(m, md5=digest(p)) for p, m in libs.items()})
    sys.exit(0)
# mode == "check": exit 0 when the published framework is current
try:
    old = json.load(open(stamp))
except (OSError, ValueError):
    sys.exit(1)
if not glob.glob(os.path.join(fw, "*.xcframework")):
    sys.exit(1)
if old.get("flags") != flags or old.get("script") != script_sum:
    sys.exit(1)
if set(old.get("libs", {})) != set(libs):
    sys.exit(1)
entries, moved = {}, False
for p, m in libs.items():
    o = old["libs"][p]
    if o["size"] == m["size"] and o["mtime"] == m["mtime"]:
        entries[p] = o
        continue
    moved = True
    if o["size"] != m["size"]:
        sys.exit(1)
    d = digest(p)
    if d != o.get("md5"):
        sys.exit(1)
    entries[p] = dict(m, md5=d)
if moved:
    write(entries)              # same bytes, newer mtime: remember it
else:
    os.utime(stamp)             # fresh for build-xcframeworks.sh's planner
sys.exit(0)
PY
}

# 0 when frameworks/ already holds exactly these archives' packaging.
impress_framework_current() {   # framework_dir build_dir lib_name script
    [ "${IMPRESS_FORCE_FRAMEWORKS:-0}" = "1" ] && return 1
    _impress_framework_stamp_tool check "$1" "$2" "$3" "$4"
}

# Record what was just published; the last line of every crate script.
impress_framework_stamp() {   # framework_dir build_dir lib_name script
    _impress_framework_stamp_tool write "$1" "$2" "$3" "$4"
}
