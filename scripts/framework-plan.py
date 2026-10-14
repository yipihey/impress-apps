#!/usr/bin/env python3
"""Which framework crates need their build script run at all.

    scripts/framework-plan.py <crate>...   -> prints the crates to build, one per line

A crate is up to date when its frameworks/.impress-stamp (written by the crate
script's last step, see scripts/build-env.sh) is newer than every file the
crate's archives can depend on: the source of every workspace crate in its
dependency closure, the lockfile and manifests, the cargo and toolchain
config, and the crate's own build script. The stamp also records the skip
flags it was built with, so switching between --fast and a full build always
rebuilds, and the archives it was built from must sit in this checkout's own
target dir: a framework copied in from another checkout (worktree setup does
this) carries that checkout's stamp, so it is always rebuilt.

This saves the cargo no-op and the stamp check for the crates an edit cannot
reach (an imbib-core edit reaches 4 of the 8 frameworks). It is conservative:
the closure comes from cargo's resolve over every feature and target, and any
newer mtime, including one from a branch switch, means "build". When unsure,
build-xcframeworks.sh --force runs every crate.
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FLAGS = ("IMPRESS_SKIP_X86", "IMPRESS_SKIP_IOS", "IMPRINT_SKIP_IOS", "IMPRINT_TECTONIC")
SKIP_DIRS = {"target", "frameworks", ".build", "generated", "headers", ".git"}
GLOBAL_INPUTS = ["Cargo.lock", "Cargo.toml", ".cargo/config.toml", "rust-toolchain.toml",
                 "scripts/build-env.sh", "scripts/native-sqlite.sh"]


def newest_mtime(path, limit):
    """True when any file under path is newer than limit (stops at the first)."""
    if os.path.isfile(path):
        return os.stat(path).st_mtime > limit
    for dirpath, dirnames, filenames in os.walk(path):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            try:
                if os.stat(os.path.join(dirpath, name)).st_mtime > limit:
                    return True
            except FileNotFoundError:
                continue
    return False


def main(crates):
    meta = json.loads(subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--offline"],
        cwd=ROOT, check=True, capture_output=True, text=True).stdout)
    target_dir = os.path.realpath(meta["target_directory"])
    by_id = {p["id"]: p for p in meta["packages"]}
    by_name = {p["name"]: p for p in meta["packages"] if p["source"] is None}
    deps = {n["id"]: n["dependencies"] for n in meta["resolve"]["nodes"]}

    def closure_dirs(name):
        seen, todo = set(), [by_name[name]["id"]]
        while todo:
            pid = todo.pop()
            if pid in seen:
                continue
            seen.add(pid)
            todo.extend(deps.get(pid, []))
        return sorted({os.path.dirname(by_id[p]["manifest_path"])
                       for p in seen if by_id[p]["source"] is None})

    flags = {k: os.environ.get(k, "") for k in FLAGS}
    for crate in crates:
        stamp = os.path.join(ROOT, "crates", crate, "frameworks", ".impress-stamp")
        reason = None
        try:
            limit = os.stat(stamp).st_mtime
            with open(stamp) as f:
                published = json.load(f)
            libs = published.get("libs") or {}
            if published.get("flags") != flags:
                reason = "built with different skip flags"
            elif not libs or not all(os.path.realpath(lib).startswith(target_dir + os.sep)
                                     for lib in libs):
                reason = "built from another checkout's target dir"
        except (OSError, ValueError):
            reason = "never published"
        if reason is None and crate not in by_name:
            reason = "not a workspace crate"
        if reason is None:
            inputs = [os.path.join(ROOT, p) for p in GLOBAL_INPUTS]
            inputs.append(os.path.join(ROOT, "crates", crate, "build-xcframework.sh"))
            inputs.extend(closure_dirs(crate))
            if any(newest_mtime(p, limit) for p in inputs if os.path.exists(p)):
                reason = "inputs changed"
        if reason:
            print(crate)
            print(f"  {crate}: {reason}", file=sys.stderr)
        else:
            print(f"  {crate}: up to date", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1:])
