#!/usr/bin/env python3
"""Run the S3 nested-host lineage XCTest against an already-built native app."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid


TEST_SELECTOR = (
    "impressTests/ScenarioRecordingProofTests/"
    "testNativeSurfaceHostCallbackPreservesAuditLineage"
)
PROOF_BUNDLE_ID = "com.impress.s3proof.impress"


def process_command(pid):
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "command="],
        check=False, capture_output=True, text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def is_owned_host(pid, executable):
    command = process_command(pid)
    return command == str(executable) or command.startswith(str(executable) + " ")


def stop_owned_host(output, executable):
    """Stop only a host PID recorded by this proof and still running our binary."""
    for marker in output.glob("host-*"):
        try:
            pid = int(marker.name.removeprefix("host-"))
        except ValueError:
            continue
        if not is_owned_host(pid, executable):
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not is_owned_host(pid, executable):
                break
            time.sleep(0.1)
        if is_owned_host(pid, executable):
            # Recheck the image immediately before escalation in case the PID
            # exited and was reused while waiting.
            if is_owned_host(pid, executable):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--derived-data", type=Path, required=True,
        help="dedicated DerivedData containing the already-built S3 proof cohort",
    )
    parser.add_argument("--cli", type=Path, required=True, help="built impress CLI executable")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    derived = args.derived_data.resolve()
    if not derived.is_dir() or not derived.name.startswith(("target-s3-", "impress-s3-")):
        parser.error("--derived-data must name the dedicated S3 proof build directory")
    if derived == Path.home() / "Library/Developer/Xcode/DerivedData":
        parser.error("do not use the shared Xcode DerivedData directory")

    products = derived / "Build/Products"
    runs = list(products.glob("impress_macosx*.xctestrun"))
    if len(runs) != 1:
        parser.error("expected one impress xctestrun; build the native cohort first")
    app = products / "Debug/impress.app"
    executable = app / "Contents/MacOS/impress"
    info_path = app / "Contents/Info.plist"
    if not info_path.is_file() or not executable.is_file():
        parser.error("the built impress app or executable is missing")
    info = plistlib.loads(info_path.read_bytes())
    if info.get("CFBundleIdentifier") != PROOF_BUNDLE_ID:
        parser.error(f"the proof build must use bundle identifier {PROOF_BUNDLE_ID}")
    cli = args.cli.resolve()
    if not cli.is_file() or not os.access(cli, os.X_OK):
        parser.error("--cli must name an existing executable")

    # Foundation canonicalizes existing /private/tmp paths to /tmp, but
    # leaves a not-yet-created database path alone. Keep the same /tmp
    # spelling for both so the hosted bootstrap ownership check agrees.
    root = Path(tempfile.mkdtemp(prefix="impress-s3-proof-", dir="/tmp"))
    (root / "bootstrap").mkdir()
    output = root / "output"
    output.mkdir()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]

    bootstrap_db = root / "bootstrap/impress.sqlite"
    env = {
        "IMPRESS_S3_PROOF": "1",
        "IMPRESS_S3_PROOF_ROOT": str(root),
        "IMPRESS_S3_PROOF_OUTPUT": str(output),
        "IMPRESS_S3_PROOF_PORT": str(port),
        "IMPRESS_S3_CLI_PATH": str(cli),
        "IMPRESS_STORE_PATH": str(bootstrap_db),
        "IMBIB_STORE_PATH": str(bootstrap_db),
        "IMPRESS_WORKSPACE": str(root / "bootstrap"),
        "IMPRESS_DEVICE_ID": "codex-s3-host-context-" + str(uuid.uuid4()),
        "IMPRESS_VERB_POLICY": "review-agent-destructive",
        "IMBIB_BACKEND": "off",
        "IMPRINT_BACKEND": "off",
        "IMPLORE_BACKEND": "off",
        "IMPART_BACKEND": "off",
        "LLVM_PROFILE_FILE": str(root / "proof-%p.profraw"),
    }

    config = plistlib.loads(runs[0].read_bytes())
    target = config.get("impressTests")
    if not isinstance(target, dict):
        parser.error("xctestrun does not contain the impressTests target")
    target["CommandLineArguments"] = [
        "--ui-testing", "-httpAutomationPort", str(port),
        "-httpAutomationEnabled", "YES", "-ApplePersistenceIgnoreState", "YES",
    ]
    target.setdefault("EnvironmentVariables", {}).update(env)
    # Keep __TESTROOT__ next to the original products, as Xcode expects.
    configured = products / (root.name + ".xctestrun")
    configured.write_bytes(plistlib.dumps(config))
    (root / "launch.json").write_text(json.dumps(env, indent=2) + "\n")
    print("Owned S3 host-context proof root:", root, flush=True)

    result = None
    try:
        subprocess.run(
            [sys.executable, str(repo / "scripts/check-native-sqlite.py"), str(app)],
            check=True,
        )
        with (root / "xcodebuild.log").open("w") as log:
            result = subprocess.run(
                [
                    "/usr/bin/xcodebuild", "test-without-building",
                    "-xctestrun", str(configured),
                    "-destination", "platform=macOS,arch=arm64",
                    f"-only-testing:{TEST_SELECTOR}",
                    "-parallel-testing-enabled", "NO",
                    "-resultBundlePath", str(root / "result.xcresult"),
                ],
                env=dict(os.environ, **env, IMPRESS_SKIP_INSTALL="1"),
                stdout=log, stderr=subprocess.STDOUT,
            )
    finally:
        configured.unlink(missing_ok=True)
        stop_owned_host(output, executable)

    proofs = list(output.glob("host-*/s3-host-callback-lineage-*.json"))
    if result is None or result.returncode:
        print("Proof failed; evidence retained at", root, file=sys.stderr)
        return result.returncode if result is not None else 1
    if len(proofs) != 1:
        print("No unique callback-lineage evidence; retained at", root, file=sys.stderr)
        return 1
    print("Passed:", proofs[0])
    print("Evidence retained:", root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
