#!/usr/bin/env python3
"""Install the worktree-aware Impress pre-push dispatcher, without clobbering custom hooks."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


LEGACY_SYMLINK = "../../apps/imbib/scripts/pre-push-dual-platform.sh"
DISPATCHER = b"""#!/bin/sh
# Resolve the pushed worktree, not the main checkout behind .git/hooks.
set -eu
impress_hook_root=$(git rev-parse --show-toplevel)
exec "$impress_hook_root/apps/imbib/scripts/pre-push-dual-platform.sh" "$@"
"""


def hook_path_for(repo_root: Path) -> Path:
    raw = subprocess.check_output(
        ["git", "-C", str(repo_root), "rev-parse", "--git-path", "hooks/pre-push"],
        text=True,
    ).strip()
    if not raw:
        raise RuntimeError("Git returned no pre-push hook path")
    path = Path(raw)
    return path if path.is_absolute() else repo_root / path


def install(hook: Path) -> bool:
    """Return True if installed; refuse any hook other than our known legacy link."""
    if hook.is_symlink():
        if os.readlink(hook) != LEGACY_SYMLINK:
            raise RuntimeError(f"refusing to replace unknown pre-push symlink: {hook}")
    elif hook.exists():
        if not hook.is_file() or hook.read_bytes() != DISPATCHER:
            raise RuntimeError(f"refusing to replace custom pre-push hook: {hook}")
        if os.access(hook, os.X_OK):
            return False

    hook.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".pre-push-impress-", dir=hook.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(DISPATCHER)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), 0o755)
        os.replace(temporary, hook)
    finally:
        temporary.unlink(missing_ok=True)
    return True


def main() -> int:
    try:
        repo_root = Path(subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], text=True,
        ).strip())
        if not (repo_root / "apps/imbib/scripts/pre-push-dual-platform.sh").is_file():
            raise RuntimeError("run this installer from an Impress Apps worktree")
        hook = hook_path_for(repo_root)
        changed = install(hook)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"pre-push installer: {error}", file=sys.stderr)
        return 1
    print(f"pre-push dispatcher {'installed at' if changed else 'already installed at'} {hook}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
