#!/usr/bin/env python3
"""Run the opt-in R3 registry proof against an already-built, isolated imprint app."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    derived = args.derived_data.resolve()
    if not derived.name.startswith(("target-r3-", "impress-r3-")):
        parser.error("--derived-data must be an owned R3 build directory")
    products = derived / "Build/Products"
    originals = list(products.glob("imprint_macosx*.xctestrun"))
    if len(originals) != 1:
        parser.error("expected one imprint xctestrun; run build-for-testing first")
    app = products / "Debug/imprint.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.impress.imprint.codex.r3":
        parser.error("the proof requires PRODUCT_BUNDLE_IDENTIFIER=com.impress.imprint.codex.r3")
    cli = args.cli.resolve()
    if not cli.is_file() or not os.access(cli, os.X_OK):
        parser.error("--cli must name an existing executable")

    root = Path(tempfile.mkdtemp(prefix="impress-r3-proof-", dir="/tmp")).resolve()
    (root / "bootstrap").mkdir()
    (root / "output").mkdir()
    (root / "compile-cache").mkdir()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]

    env = {
        "IMPRESS_R3_PROOF": "1", "IMPRESS_R3_PROOF_ROOT": str(root),
        "IMPRESS_R3_PROOF_OUTPUT": str(root / "output"),
        "IMPRESS_R3_PROOF_PORT": str(port), "IMPRESS_R3_CLI_PATH": str(cli),
        "IMPRESS_STORE_PATH": str(root / "bootstrap/impress.sqlite"),
        "IMBIB_STORE_PATH": str(root / "bootstrap/impress.sqlite"),
        "IMPRESS_WORKSPACE": str(root / "bootstrap"),
        "IMPRESS_DEVICE_ID": "codex-r3-" + str(uuid.uuid4()),
        "IMPRINT_COMPILE_CACHE_DIR": str(root / "compile-cache"),
        "LLVM_PROFILE_FILE": str(root / "proof-%p.profraw"),
        "IMPRESS_VERB_POLICY": "review-agent-destructive",
        "IMBIB_BACKEND": "off", "IMPRINT_BACKEND": "off",
        "IMPLORE_BACKEND": "off", "IMPART_BACKEND": "off",
    }
    config = plistlib.loads(originals[0].read_bytes())
    target = config["imprintTests"]
    target["CommandLineArguments"] = [
        "--ui-testing", "-httpAutomationPort", str(port),
        "-httpAutomationEnabled", "YES", "-ApplePersistenceIgnoreState", "YES",
    ]
    target.setdefault("EnvironmentVariables", {}).update(env)
    configured = products / (root.name + ".xctestrun")
    configured.write_bytes(plistlib.dumps(config))
    (root / "launch.json").write_text(json.dumps(env, indent=2))
    print("Owned R3 proof root:", root, flush=True)
    result = None
    try:
        subprocess.run([
            sys.executable, str(repo / "scripts/check-native-sqlite.py"), str(app)
        ], check=True)
        with (root / "xcodebuild.log").open("w") as log:
            result = subprocess.run([
                "/usr/bin/xcodebuild", "test-without-building", "-xctestrun", str(configured),
                "-destination", "platform=macOS,arch=arm64",
                "-only-testing:imprintTests/ImprintRegistryProofTests",
                "-parallel-testing-enabled", "NO",
                "-resultBundlePath", str(root / "result.xcresult"),
            ], env=dict(os.environ, **env, IMPRESS_SKIP_INSTALL="1"),
                stdout=log, stderr=subprocess.STDOUT)
    finally:
        configured.unlink(missing_ok=True)
    proofs = list((root / "output").glob("host-*/proof.json"))
    if result is None or result.returncode:
        print("Proof failed; see", root / "xcodebuild.log", file=sys.stderr)
        return result.returncode if result is not None else 1
    if len(proofs) != 1:
        print("No completed native proof evidence", file=sys.stderr)
        return 1
    print("Passed:", proofs[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
