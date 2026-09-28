"""Small Mach-O/nm fixtures for the prelaunch native-symbol barrier."""

import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "check-native-sqlite.py"
SPEC = importlib.util.spec_from_file_location("check_native_sqlite", SCRIPT)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class NativeSymbolCheckTests(unittest.TestCase):
    def test_macho_fixture_detects_sqlite_and_private_rust_but_allows_uniffi_and_cpp(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "imprint.app"
            executable = bundle / "Contents" / "MacOS" / "imprint"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(bytes.fromhex("feedfacf") + b"fixture")
            output = "\n".join((
                "0000000000001000 T _sqlite3_open_v2",
                "0000000000002000 T __RNvNtC4demo4core8dispatch",
                "0000000000003000 T __ZN4demo8dispatch17h0123456789abcdefE",
                "0000000000004000 T __ZN3foo3barEv",  # C++ mangling, not Rust
                "0000000000005000 T _uniffi_imbib_ffi_fn_dispatch_verb",
            ))
            nm = subprocess.CompletedProcess([], 0, stdout=output, stderr="")
            with mock.patch.object(CHECKER.subprocess, "run", return_value=nm):
                checked, sqlite, rust = CHECKER.check_bundle(bundle)
            relative = Path("Contents/MacOS/imprint")
            self.assertEqual(checked, 1)
            self.assertEqual(sqlite, [relative])
            self.assertEqual(len(rust[relative]), 2)

    def test_no_macho_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "imprint.app"
            bundle.mkdir()
            (bundle / "text.txt").write_text("not a Mach-O")
            with self.assertRaisesRegex(RuntimeError, "no Mach-O files"):
                CHECKER.check_bundle(bundle)

    def test_file_symlink_cannot_escape_owned_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "imprint.app"
            bundle.mkdir()
            outside = root / "outside"
            outside.write_bytes(bytes.fromhex("feedfacf"))
            (bundle / "escape").symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "escapes app"):
                CHECKER.check_bundle(bundle)

    def test_cli_reports_symbol_count_and_owned_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "imprint.app"
            executable = bundle / "Contents" / "MacOS" / "imprint"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(bytes.fromhex("feedfacf"))
            nm = subprocess.CompletedProcess([], 0,
                stdout="0000000000002000 T __RNvNtC4demo4core8dispatch\n", stderr="")
            stderr = io.StringIO()
            with mock.patch.object(CHECKER.subprocess, "run", return_value=nm), \
                 mock.patch.object(sys, "argv", [str(SCRIPT), str(bundle)]), \
                 contextlib.redirect_stderr(stderr), \
                 self.assertRaises(SystemExit) as exit_result:
                CHECKER.main()
            self.assertEqual(exit_result.exception.code, 1)
            self.assertIn("1 private Rust exports", stderr.getvalue())
            self.assertIn("Contents/MacOS/imprint (1)", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
