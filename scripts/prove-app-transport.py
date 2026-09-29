#!/usr/bin/env python3
"""Build or run P5b's hosted native HTTP proof against one owned app instance.

The build and test products stay in a target-p5b-* DerivedData directory. The
app is launched only by xcodebuild test-without-building, after the hosted test
has been configured with a unique bundle, port, device, and scratch workspace.
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


APPS = ("imbib", "imprint", "impart", "implore", "impel")


def selected_tests(app):
    target = app + "Tests"
    tests = [target + "/TransportProofTests"]
    if app == "imbib":
        tests.append(target + "/ImbibNativeContractProofTests")
        tests.append(target + "/CollectionMembershipContractTests")
        tests.append(target + "/LibraryDeletionContractTests")
    if app == "imprint":
        tests.append(target + "/ImprintNativeVerbProofTests")
    if app == "implore":
        tests.append(target + "/ImploreNativeVerbProofTests")
    return tests


def run(command, *, cwd, env, log):
    with log.open("a") as output:
        output.write("$ " + " ".join(command) + "\n")
        output.flush()
        subprocess.run(command, cwd=cwd, env=env, stdout=output,
                       stderr=subprocess.STDOUT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", choices=APPS)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--derived-data", type=Path,
                        help="Owned target-p5b-* DerivedData directory in this worktree")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    app_dir = repo / ("apps/imbib/imbib" if args.app == "imbib" else "apps/" + args.app)
    derived = (args.derived_data or repo / ("target-p5b-transport-" + args.app)).resolve()
    if derived.parent != repo or not derived.name.startswith("target-p5b-"):
        parser.error("--derived-data must be an owned target-p5b-* directory in this worktree")
    proof = Path(tempfile.mkdtemp(prefix="impress-p5b-transport-", dir="/tmp"))
    bootstrap = proof / "bootstrap"
    bootstrap.mkdir()
    output = proof / "output"
    output.mkdir()
    compile_cache = proof / "compile-cache"
    compile_cache.mkdir()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    env = dict(os.environ)
    env.pop("IMPRESS_APP_TOKEN", None)
    env.pop("IMPRINT_SELFTEST_WAL_HEALTH_URL", None)
    env["IMPRESS_SKIP_INSTALL"] = "1"
    tests = selected_tests(args.app)
    only = ["-only-testing:" + test for test in tests]
    print("Owned proof:", proof, flush=True)
    if not args.skip_build:
        run(["xcodegen", "generate"], cwd=app_dir, env=env, log=proof / "build.log")
        run([
            "/usr/bin/xcodebuild", "build-for-testing", "-project",
            str(app_dir / (args.app + ".xcodeproj")), "-scheme", args.app,
            "-configuration", "Debug", "-destination", "platform=macOS",
            "-derivedDataPath", str(derived), "-jobs", "6", *only,
            "CODE_SIGNING_ALLOWED=NO", "IMPRESS_SKIP_INSTALL=1",
            "DEAD_CODE_STRIPPING=YES",
            "PRODUCT_BUNDLE_IDENTIFIER=com.impress.p5bproof." + args.app,
        ], cwd=repo, env=env, log=proof / "build.log")
    # Check the exact app to be hosted, including its nested test plugin and
    # frameworks, on both fresh-build and --skip-build paths. A bundled SQLite
    # definition must never be launched alongside another SQLite copy.
    app_bundle = derived / "Build/Products/Debug" / (args.app + ".app")
    run([sys.executable, str(repo / "scripts/check-native-sqlite.py"), str(app_bundle)],
        cwd=repo, env=env, log=proof / "build.log")
    if args.build_only:
        print("Build-only complete; no app was launched.", flush=True)
        return
    products = derived / "Build/Products"
    candidates = list(products.glob(args.app + "_*.xctestrun"))
    if len(candidates) != 1:
        raise RuntimeError("Expected exactly one built xctestrun: " + str(candidates))
    config = plistlib.loads(candidates[0].read_bytes())
    target = config[args.app + "Tests"]
    target["CommandLineArguments"] = [
        "--ui-testing", "-httpAutomationPort", str(port),
        "-httpAutomationEnabled", "YES", "-ApplePersistenceIgnoreState", "YES",
    ]
    overrides = {
        "IMPRESS_P5B_TRANSPORT_PROOF": "1", "IMPRESS_P5B_APP": args.app,
        "IMPRESS_P5B_PORT": str(port), "IMPRESS_P5B_ROOT": str(proof),
        "IMPRESS_P5B_OUTPUT": str(output),
        "IMPRESS_STORE_PATH": str(bootstrap / "impress.sqlite"),
        "IMBIB_STORE_PATH": str(bootstrap / "impress.sqlite"),
        "IMPRESS_WORKSPACE": str(bootstrap),
        "IMPRESS_DEVICE_ID": "codex-p5b-" + str(uuid.uuid4()),
        "IMPRINT_COMPILE_CACHE_DIR": str(compile_cache),
        "IMBIB_LIBRARY_FILES_MIGRATION": "off",
    }
    if args.app == "imprint":
        overrides.update(IMPRINT_P5B_PROOF="1", IMPRINT_P5B_PROOF_PORT=str(port))
    if args.app == "implore":
        overrides.update(IMPRESS_P5B_IMPLORE_PROOF="1", IMPRESS_P5B_IMPLORE_PORT=str(port))
    target.setdefault("EnvironmentVariables", {}).update(overrides)
    configured = products / ("p5b-transport-" + args.app + ".xctestrun")
    configured.write_bytes(plistlib.dumps(config))
    run([
        "/usr/bin/xcodebuild", "test-without-building", "-xctestrun", str(configured),
        "-destination", "platform=macOS", *only,
        "-parallel-testing-enabled", "NO",
        "-resultBundlePath", str(proof / "result.xcresult"),
    ], cwd=repo, env=dict(env, **overrides), log=proof / "test.log")
    evidence = json.loads((output / "proof.json").read_text())
    pid = evidence["pid"]
    store = Path(evidence["store"]).resolve()
    owned_store = (store.is_absolute() and store.name == "impress.sqlite"
                   and store.parent.name == "workspace"
                   and store.parent.parent.name == f"impress-unit-tests-{pid}")
    if (evidence["app"] != args.app or evidence["port"] != port
            or not owned_store
            or not any(item["path"] == "/api/verb/surface-demo-service_series"
                       and item["status"] == 200 for item in evidence["calls"])
            or "logs" not in evidence):
        raise RuntimeError("Hosted proof did not report owned positive transport evidence")
    print(json.dumps({"app": args.app, "proof": str(proof), "pid": pid,
                      "calls": len(evidence["calls"]), "tests": tests}, indent=2))


if __name__ == "__main__":
    main()
