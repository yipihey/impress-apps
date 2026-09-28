#!/usr/bin/env python3
"""Run one pre-push chassis interlock suite in an owned macOS test host.

The hook supplies the same app/test suite it previously passed to `xcodebuild
test`. This runner first builds without launching, verifies the fresh app's
unique bundle identity, then copies (never edits) the generated xctestrun to
inject an owned workspace, device id and HTTP port before launch.
"""

import argparse
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import uuid


SUITES = {
    "impel": "impelTests/ImpelChassisFlipTests",
    "impart": "impartTests/ImpartChassisFlipTests",
    "impress": "impressTests/ImpressShellTests",
}


def build_command(app: str, app_dir: Path, derived: Path, bundle_id: str) -> list[str]:
    return [
        "/usr/bin/xcodebuild", "build-for-testing",
        "-derivedDataPath", str(derived),
        "-project", str(app_dir / f"{app}.xcodeproj"),
        "-scheme", app, "-configuration", "Debug",
        "-destination", "platform=macOS",
        f"-only-testing:{SUITES[app]}",
        "IMPRESS_SKIP_INSTALL=1", "CODE_SIGN_IDENTITY=-",
        "CODE_SIGNING_REQUIRED=NO", "CODE_SIGNING_ALLOWED=NO",
        "DEAD_CODE_STRIPPING=YES", f"PRODUCT_BUNDLE_IDENTIFIER={bundle_id}",
    ]


def test_command(configured: Path, app: str, result_bundle: Path) -> list[str]:
    return [
        "/usr/bin/xcodebuild", "test-without-building",
        "-xctestrun", str(configured), "-destination", "platform=macOS",
        f"-only-testing:{SUITES[app]}",
        "-parallel-testing-enabled", "NO",
        "-resultBundlePath", str(result_bundle),
    ]


def validate_bundle(app_bundle: Path, bundle_id: str) -> None:
    info_path = app_bundle / "Contents/Info.plist"
    if not info_path.is_file():
        raise RuntimeError(f"no owned built app at {app_bundle}")
    info = plistlib.loads(info_path.read_bytes())
    if info.get("CFBundleIdentifier") != bundle_id:
        raise RuntimeError(
            f"built app has bundle id {info.get('CFBundleIdentifier')!r}, expected {bundle_id!r}"
        )
    executable = info.get("CFBundleExecutable")
    if not executable or not (app_bundle / "Contents/MacOS" / executable).is_file():
        raise RuntimeError(f"built app has no executable: {app_bundle}")


def configure_xctestrun(
    original: Path, configured: Path, app: str, port: int, environment: dict[str, str]
) -> None:
    if original == configured:
        raise ValueError("configured xctestrun must be a copy")
    config = plistlib.loads(original.read_bytes())
    target_name = f"{app}Tests"
    if target_name not in config:
        raise RuntimeError(f"{original} has no {target_name} target")
    target = config[target_name]
    target["CommandLineArguments"] = [
        "--ui-testing", "-httpAutomationPort", str(port),
        "-httpAutomationEnabled", "YES",
        "-ApplePersistenceIgnoreState", "YES",
    ]
    target.setdefault("EnvironmentVariables", {}).update(environment)
    configured.write_bytes(plistlib.dumps(config))


def unused_local_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def run_logged(command: list[str], log: Path, environment: dict[str, str]) -> None:
    with log.open("a") as output:
        output.write("$ " + " ".join(command) + "\n")
        output.flush()
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, env=environment)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}); see {log}")


def run(app: str, repo_root: Path, log: Path) -> None:
    app_dir = repo_root / "apps" / app
    derived = app_dir / ".ci-derived"
    products = derived / "Build/Products"
    run_id = uuid.uuid4().hex
    bundle_id = f"com.impress.codex.interlock.{app}.{run_id}"
    scratch = log.parent / f"interlock-{app}-{run_id}"
    workspace = scratch / "workspace"
    workspace.mkdir(parents=True)
    (scratch / "compile-cache").mkdir()
    port = unused_local_port()
    overrides = {
        "IMPRESS_STORE_PATH": str(workspace / "impress.sqlite"),
        "IMBIB_STORE_PATH": str(workspace / "impress.sqlite"),
        "IMPRESS_WORKSPACE": str(workspace),
        "IMPRESS_DEVICE_ID": f"codex-interlock-{run_id}",
        "IMPRINT_COMPILE_CACHE_DIR": str(scratch / "compile-cache"),
        "LLVM_PROFILE_FILE": str(scratch / "profile-%p.profraw"),
        "IMBIB_LIBRARY_FILES_MIGRATION": "off",
        "IMBIB_BACKEND": "off", "IMPRINT_BACKEND": "off",
        "IMPLORE_BACKEND": "off", "IMPART_BACKEND": "off",
        "IMPRESS_SKIP_INSTALL": "1",
    }
    environment = dict(os.environ)
    environment.pop("IMPRESS_APP_TOKEN", None)
    environment.pop("IMPRINT_SELFTEST_WAL_HEALTH_URL", None)
    environment.update(overrides)
    log.write_text(f"Owned interlock root: {scratch}\nHTTP port: {port}\n")

    run_logged(build_command(app, app_dir, derived, bundle_id), log, environment)
    app_bundle = products / "Debug" / f"{app}.app"
    validate_bundle(app_bundle, bundle_id)
    run_logged(
        [sys.executable, str(repo_root / "scripts/check-native-sqlite.py"), str(app_bundle)],
        log, environment,
    )

    originals = list(products.glob(f"{app}_macosx*.xctestrun"))
    if len(originals) != 1:
        raise RuntimeError(f"expected one original {app} xctestrun, found {originals}")
    configured = products / f"codex-interlock-{app}-{run_id}.xctestrun"
    try:
        configure_xctestrun(originals[0], configured, app, port, overrides)
        run_logged(test_command(configured, app, scratch / "result.xcresult"), log, environment)
    finally:
        configured.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--app", choices=sorted(SUITES), required=True)
    parser.add_argument("--only-testing", required=True)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    if args.only_testing != SUITES[args.app]:
        parser.error(f"{args.app} interlock suite must be {SUITES[args.app]}")
    try:
        run(args.app, args.repo_root.resolve(), args.log.resolve())
    except (OSError, ValueError, RuntimeError) as error:
        print(f"interlock {args.app}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
