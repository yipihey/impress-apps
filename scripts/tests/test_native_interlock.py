"""No-launch fixtures for the pre-push hosted interlock runner."""

import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "test-native-interlock.py"
SPEC = importlib.util.spec_from_file_location("test_native_interlock_runner", SCRIPT)
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class NativeInterlockTests(unittest.TestCase):
    def test_copy_owns_launch_arguments_and_leaves_original_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = root / "impel_macosx.xctestrun"
            original.write_bytes(plistlib.dumps({
                "impelTests": {"CommandLineArguments": ["--old"], "EnvironmentVariables": {"KEEP": "yes"}},
                "__xctestrun_metadata__": {"FormatVersion": 2},
            }))
            before = original.read_bytes()
            configured = root / "codex-interlock.xctestrun"
            RUNNER.configure_xctestrun(
                original, configured, "impel", 24901,
                {"IMPRESS_WORKSPACE": str(root / "workspace"), "IMBIB_BACKEND": "off"},
            )
            self.assertEqual(original.read_bytes(), before)
            target = plistlib.loads(configured.read_bytes())["impelTests"]
            self.assertEqual(target["CommandLineArguments"], [
                "--ui-testing", "-httpAutomationPort", "24901",
                "-httpAutomationEnabled", "YES", "-ApplePersistenceIgnoreState", "YES",
            ])
            self.assertEqual(target["EnvironmentVariables"]["KEEP"], "yes")
            self.assertEqual(target["EnvironmentVariables"]["IMBIB_BACKEND"], "off")
            self.assertEqual(target["EnvironmentVariables"]["IMPRESS_WORKSPACE"], str(root / "workspace"))

    def test_bundle_validation_refuses_stale_or_missing_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "impel.app"
            info = bundle / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.impress.codex.interlock.impel.current",
                "CFBundleExecutable": "impel",
            }))
            with self.assertRaisesRegex(RuntimeError, "no executable"):
                RUNNER.validate_bundle(bundle, "com.impress.codex.interlock.impel.current")
            executable = bundle / "Contents/MacOS/impel"
            executable.parent.mkdir()
            executable.write_bytes(b"fixture")
            with self.assertRaisesRegex(RuntimeError, "bundle id"):
                RUNNER.validate_bundle(bundle, "com.impress.codex.interlock.impel.other")
            RUNNER.validate_bundle(bundle, "com.impress.codex.interlock.impel.current")

    def test_runner_builds_first_then_runs_only_original_suite_with_owned_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app_dir = root / "apps/impel"
            products = app_dir / ".ci-derived/Build/Products"
            bundle = products / "Debug/impel.app"
            info = bundle / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            run_id = "a" * 32
            bundle_id = f"com.impress.codex.interlock.impel.{run_id}"
            info.write_bytes(plistlib.dumps({
                "CFBundleIdentifier": bundle_id, "CFBundleExecutable": "impel",
            }))
            executable = bundle / "Contents/MacOS/impel"
            executable.parent.mkdir()
            executable.write_bytes(b"fixture")
            original = products / "impel_macosx.xctestrun"
            original.write_bytes(plistlib.dumps({"impelTests": {}}))
            original_bytes = original.read_bytes()
            log = root / "logs/interlock-impel.log"
            log.parent.mkdir()
            commands = []

            def no_launch(command, **_kwargs):
                commands.append(command)
                if "test-without-building" in command:
                    configured = Path(command[command.index("-xctestrun") + 1])
                    self.assertTrue(configured.is_file())
                    target = plistlib.loads(configured.read_bytes())["impelTests"]
                    self.assertIn("--ui-testing", target["CommandLineArguments"])
                    self.assertTrue(target["EnvironmentVariables"]["IMPRESS_WORKSPACE"].startswith(str(log.parent)))
                    self.assertEqual(target["EnvironmentVariables"]["IMBIB_BACKEND"], "off")
                return subprocess.CompletedProcess(command, 0)

            with mock.patch.object(RUNNER.uuid, "uuid4", return_value=SimpleNamespace(hex=run_id)), \
                 mock.patch.object(RUNNER, "unused_local_port", return_value=24901), \
                 mock.patch.object(RUNNER.subprocess, "run", side_effect=no_launch):
                RUNNER.run("impel", root, log)

            self.assertEqual(len(commands), 3)
            self.assertIn("build-for-testing", commands[0])
            self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER={bundle_id}", commands[0])
            self.assertIn("IMPRESS_SKIP_INSTALL=1", commands[0])
            self.assertIn("test-without-building", commands[2])
            self.assertNotIn("test", commands[2])
            self.assertIn("-only-testing:impelTests/ImpelChassisFlipTests", commands[2])
            self.assertEqual(original.read_bytes(), original_bytes)
            self.assertEqual(list(products.glob("codex-interlock-*.xctestrun")), [])
            self.assertTrue(log.is_file())


if __name__ == "__main__":
    unittest.main()
