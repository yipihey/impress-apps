#!/usr/bin/env python3
"""Run the opt-in provider proof against an isolated, already-built impress app."""

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
    parser.add_argument("--mcp", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    products = args.derived_data.resolve() / "Build/Products"
    originals = list(products.glob("impress_macosx*.xctestrun"))
    if len(originals) != 1:
        parser.error("expected one impress xctestrun; run build-for-testing first")
    app = products / "Debug/impress.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.impress.impress.codex.p8":
        parser.error("the proof requires PRODUCT_BUNDLE_IDENTIFIER=com.impress.impress.codex.p8")
    mcp, cli = args.mcp.resolve(), args.cli.resolve()
    if not all(os.access(path, os.X_OK) for path in (mcp, cli)):
        parser.error("--mcp and --cli must name built executable files")

    root = Path(tempfile.mkdtemp(prefix="impress-p8-proof-", dir="/tmp")).resolve()
    (root / "bootstrap").mkdir()
    (root / "output").mkdir()
    # Reserve both simultaneously to avoid choosing the same ephemeral port.
    # Release just before XCTest; a bind race fails the proof, never falls back.
    with socket.socket() as app_socket, socket.socket() as mcp_socket:
        app_socket.bind(("127.0.0.1", 0))
        mcp_socket.bind(("127.0.0.1", 0))
        app_port = app_socket.getsockname()[1]
        mcp_port = mcp_socket.getsockname()[1]

    env = {
        "IMPRESS_P8_PROOF": "1", "IMPRESS_P8_PROOF_ROOT": str(root),
        "IMPRESS_P8_PROOF_OUTPUT": str(root / "output"),
        "IMPRESS_P8_PROOF_PORT": str(app_port), "IMPRESS_P8_MCP_PORT": str(mcp_port),
        "IMPRESS_P8_MCP_PATH": str(mcp), "IMPRESS_P8_CLI_PATH": str(cli),
        "IMPRESS_P8_PROVIDER_SCRIPT": str(repo / "examples/runtime-provider.py"),
        "IMPRESS_P8_PYTHON": sys.executable,
        "IMPRESS_STORE_PATH": str(root / "bootstrap/impress.sqlite"),
        "IMBIB_STORE_PATH": str(root / "bootstrap/impress.sqlite"),
        "IMPRESS_WORKSPACE": str(root / "bootstrap"),
        "IMPRESS_DEVICE_ID": "codex-p8-" + str(uuid.uuid4()),
        "IMPRINT_COMPILE_CACHE_DIR": str(root / "compile-cache"),
        "LLVM_PROFILE_FILE": str(root / "proof-%p.profraw"),
        "IMPRESS_VERB_POLICY": "review-agent-destructive",
        "IMBIB_BACKEND": "off", "IMPRINT_BACKEND": "off",
        "IMPLORE_BACKEND": "off", "IMPART_BACKEND": "off",
    }
    config = plistlib.loads(originals[0].read_bytes())
    target = config["impressTests"]
    target["CommandLineArguments"] = [
        "--ui-testing", "-httpAutomationPort", str(app_port),
        "-httpAutomationEnabled", "YES", "-ApplePersistenceIgnoreState", "YES",
    ]
    target.setdefault("EnvironmentVariables", {}).update(env)
    # Keep __TESTROOT__ anchored beside the original build products.
    configured = products / (root.name + ".xctestrun")
    configured.write_bytes(plistlib.dumps(config))
    (root / "launch.json").write_text(json.dumps(env, indent=2))
    print("Owned proof root:", root, flush=True)
    try:
        subprocess.run([
            sys.executable, str(repo / "scripts/check-native-sqlite.py"), str(app)
        ], check=True)
        with (root / "xcodebuild.log").open("w") as log:
            result = subprocess.run([
                "/usr/bin/xcodebuild", "test-without-building", "-xctestrun", str(configured),
                "-destination", "platform=macOS,arch=arm64",
                "-only-testing:impressTests/RuntimeProviderProofTests",
                "-parallel-testing-enabled", "NO",
                "-resultBundlePath", str(root / "result.xcresult"),
            ], env=dict(os.environ, **env, IMPRESS_SKIP_INSTALL="1"),
                stdout=log, stderr=subprocess.STDOUT)
    finally:
        configured.unlink()
    proofs = list((root / "output").glob("host-*/proof.json"))
    if result.returncode:
        print("Proof failed; see", root / "xcodebuild.log", file=sys.stderr)
        return result.returncode
    if len(proofs) != 1:
        print("No completed native proof evidence", file=sys.stderr)
        return 1
    print("Passed:", proofs[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
