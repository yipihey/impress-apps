#!/usr/bin/env python3
"""Build and run G5's hosted Tier B proof without installing or opening user apps.

Run once per app after rebuilding the Rust archive cohort. The test verifies
its actual native store and token paths before sending any request.
"""
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
    parser.add_argument("app", choices=("imbib", "imprint", "implore", "impel", "impart"))
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--derived-data", type=Path, help="Reuse an owned target-g5-* or target-p5b-* build directory sequentially")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    cli = args.cli.resolve(strict=True)
    if not os.access(cli, os.X_OK):
        parser.error("--cli must be an executable from this revision")
    app_dir = repo / ("apps/imbib/imbib" if args.app == "imbib" else "apps/" + args.app)
    derived = (args.derived_data or repo / ("target-g5-proof-" + args.app)).resolve()
    if derived.parent != repo or not derived.name.startswith(("target-g5-", "target-p5b-")):
        parser.error("--derived-data must be an owned target-g5-* or target-p5b-* directory in this worktree")
    proof = Path(tempfile.mkdtemp(prefix="impress-g5-proof-", dir="/tmp"))
    bootstrap = proof / "bootstrap"
    bootstrap.mkdir()
    compile_cache = proof / "compile-cache"
    compile_cache.mkdir()
    output = proof / "output"
    output.mkdir()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    env = dict(os.environ, IMPRESS_SKIP_INSTALL="1")
    print("Owned proof:", proof, flush=True)
    if not args.skip_build:
        with (proof / "build.log").open("w") as log:
            subprocess.run(["xcodegen", "generate"], cwd=app_dir, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            subprocess.run([
                "/usr/bin/xcodebuild", "build-for-testing", "-project", str(app_dir / (args.app + ".xcodeproj")),
                "-scheme", args.app, "-configuration", "Debug", "-destination", "platform=macOS",
                "-derivedDataPath", str(derived), "-jobs", "6",
                "-only-testing:" + args.app + "Tests/StrictArgumentsProofTests",
                "CODE_SIGNING_ALLOWED=NO", "IMPRESS_SKIP_INSTALL=1",
                # Package test products do not inherit the app project's setting.
                # They co-link the same Rust archives and need the same stripping.
                "DEAD_CODE_STRIPPING=YES",
                "PRODUCT_BUNDLE_IDENTIFIER=com.impress.g5proof." + args.app,
            ], cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    # Both a fresh build and --skip-build must pass the same bundle check
    # before test-without-building can launch the app.
    app_bundle = derived / "Build/Products/Debug" / (args.app + ".app")
    with (proof / "build.log").open("a") as log:
        subprocess.run(
            [sys.executable, str(repo / "scripts/check-native-sqlite.py"), str(app_bundle)],
            cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT, check=True,
        )
    if args.build_only:
        return
    products = derived / "Build/Products"
    candidates = list(products.glob(args.app + "_*.xctestrun"))
    if len(candidates) != 1:
        raise RuntimeError("Expected exactly one built xctestrun: " + str(candidates))
    config = plistlib.loads(candidates[0].read_bytes())
    target_name = args.app + "Tests"
    target = config[target_name]
    target["CommandLineArguments"] = [
        "--ui-testing", "-httpAutomationPort", str(port), "-httpAutomationEnabled", "YES",
        "-ApplePersistenceIgnoreState", "YES",
    ]
    overrides = {
        "IMPRESS_G5_PROOF": "1", "IMPRESS_G5_APP": args.app, "IMPRESS_G5_PORT": str(port),
        "IMPRESS_G5_CLI": str(cli), "IMPRESS_G5_ROOT": str(proof), "IMPRESS_G5_OUTPUT": str(output),
        "IMPRESS_STORE_PATH": str(bootstrap / "impress.sqlite"),
        "IMBIB_STORE_PATH": str(bootstrap / "impress.sqlite"),
        "IMPRINT_COMPILE_CACHE_DIR": str(compile_cache),
        "IMPRESS_WORKSPACE": str(bootstrap), "IMPRESS_DEVICE_ID": "codex-g5-" + str(uuid.uuid4()),
        "IMBIB_LIBRARY_FILES_MIGRATION": "off",
    }
    target.setdefault("EnvironmentVariables", {}).update(overrides)
    configured = products / ("g5-proof-" + args.app + ".xctestrun")
    configured.write_bytes(plistlib.dumps(config))
    command = [
        "/usr/bin/xcodebuild", "test-without-building", "-xctestrun", str(configured),
        "-destination", "platform=macOS", "-only-testing:" + target_name + "/StrictArgumentsProofTests",
        "-parallel-testing-enabled", "NO", "-resultBundlePath", str(proof / "result.xcresult"),
    ]
    if args.app == "imprint":
        command.append("-only-testing:imprintTests/LegacyPersistenceIsolationTests")
    with (proof / "test.log").open("w") as log:
        subprocess.run(command, cwd=repo, env=dict(env, **overrides), stdout=log, stderr=subprocess.STDOUT, check=True)
    evidence = json.loads((output / "proof.json").read_text())
    print(json.dumps({"app": args.app, "proof": str(proof), "pid": evidence["pid"],
                      "scenario": evidence["scenario"], "surface": evidence["surface"], "layout": evidence["layout"]}, indent=2))


if __name__ == "__main__":
    main()
