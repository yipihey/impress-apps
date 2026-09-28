"""Filesystem fixtures for the shared, worktree-aware hook installer."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "install-pre-push-hook.py"
SPEC = importlib.util.spec_from_file_location("install_pre_push_hook", SCRIPT)
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


class PrePushInstallerTests(unittest.TestCase):
    def test_atomically_replaces_only_known_legacy_link_without_writing_its_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hook = root / ".git/hooks/pre-push"
            hook.parent.mkdir(parents=True)
            target = root / "apps/imbib/scripts/pre-push-dual-platform.sh"
            target.parent.mkdir(parents=True)
            target.write_text("#!/bin/sh\necho main's old stage\n")
            old_contents = target.read_bytes()
            hook.symlink_to(INSTALLER.LEGACY_SYMLINK)

            self.assertTrue(INSTALLER.install(hook))
            self.assertFalse(hook.is_symlink())
            self.assertEqual(hook.read_bytes(), INSTALLER.DISPATCHER)
            self.assertTrue(os.access(hook, os.X_OK))
            self.assertEqual(target.read_bytes(), old_contents)
            self.assertEqual(list(hook.parent.glob(".pre-push-impress-*")), [])
            self.assertFalse(INSTALLER.install(hook), "installing twice must be a no-op")

    def test_refuses_unknown_custom_hook_or_symlink_without_changing_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hook = root / "pre-push"
            hook.write_text("#!/bin/sh\necho custom\n")
            before = hook.read_bytes()
            with self.assertRaisesRegex(RuntimeError, "custom pre-push hook"):
                INSTALLER.install(hook)
            self.assertEqual(hook.read_bytes(), before)

            hook.unlink()
            hook.symlink_to("another-hook")
            with self.assertRaisesRegex(RuntimeError, "unknown pre-push symlink"):
                INSTALLER.install(hook)
            self.assertTrue(hook.is_symlink())
            self.assertEqual(os.readlink(hook), "another-hook")

    def test_dispatcher_uses_invoking_worktree_not_hook_location(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hook = root / ".git/hooks/pre-push"
            INSTALLER.install(hook)
            worktree = root / "feature-worktree"
            target = worktree / "apps/imbib/scripts/pre-push-dual-platform.sh"
            target.parent.mkdir(parents=True)
            marker = root / "ran.txt"
            target.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$1\" > '{marker}'\n")
            target.chmod(0o755)
            git = root / "bin/git"
            git.parent.mkdir()
            git.write_text(f"#!/bin/sh\nprintf '%s\\n' '{worktree}'\n")
            git.chmod(0o755)
            environment = dict(os.environ, PATH=f"{git.parent}:{os.environ['PATH']}")

            subprocess.run([str(hook), "remote-name"], cwd=worktree, env=environment, check=True)
            self.assertEqual(marker.read_text(), "remote-name\n")


if __name__ == "__main__":
    unittest.main()
