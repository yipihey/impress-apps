#!/usr/bin/env python3
"""Refuse a hosted app bundle with private SQLite or Rust exports.

Only the bundle named on the command line is inspected. Its nested test
plugins and frameworks are included; unrelated build products are not.
"""

import argparse
import os
from pathlib import Path
import re
import subprocess


MACH_O_MAGIC = {
    bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",  # thin
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",  # universal
    )
}
SQLITE_DEFINITION = re.compile(r"(?<!\w)_sqlite3_open_v2(?!\w)")
RUST_LEGACY_SYMBOL = re.compile(r"__ZN.*17h[0-9a-f]{16}E\Z")


def private_rust_symbols(nm_output: str) -> list[str]:
    """Find Rust mangling without rejecting UniFFI C or unrelated C++ exports."""
    symbols = (line.split()[-1] for line in nm_output.splitlines() if line.split())
    return [symbol for symbol in symbols
            if symbol.startswith("__R") or RUST_LEGACY_SYMBOL.fullmatch(symbol)]


def check_bundle(bundle: Path) -> tuple[int, list[Path], dict[Path, list[str]]]:
    bundle = bundle.resolve(strict=True)
    if not bundle.is_dir() or bundle.suffix != ".app":
        raise ValueError(f"expected one built .app bundle: {bundle}")

    seen: set[Path] = set()
    checked = 0
    sqlite_offenders: list[Path] = []
    rust_offenders: dict[Path, list[str]] = {}
    for directory, subdirs, files in os.walk(bundle, followlinks=False):
        for name in subdirs:
            link = Path(directory) / name
            if link.is_symlink() and not link.resolve(strict=True).is_relative_to(bundle):
                raise ValueError(f"bundle directory symlink escapes app: {link}")
        for name in files:
            path = Path(directory) / name
            target = path.resolve(strict=True)
            if not target.is_relative_to(bundle):
                raise ValueError(f"bundle file symlink escapes app: {path}")
            if target in seen or not target.is_file():
                continue
            seen.add(target)
            with target.open("rb") as stream:
                if stream.read(4) not in MACH_O_MAGIC:
                    continue
            checked += 1
            result = subprocess.run(
                ["/usr/bin/nm", "-gU", str(target)],
                capture_output=True, text=True, check=False,
            )
            if result.returncode != 0:
                raise RuntimeError(f"nm failed for {target}: {result.stderr.strip()}")
            if SQLITE_DEFINITION.search(result.stdout):
                sqlite_offenders.append(target.relative_to(bundle))
            rust_symbols = private_rust_symbols(result.stdout)
            if rust_symbols:
                rust_offenders[target.relative_to(bundle)] = rust_symbols
    if checked == 0:
        raise RuntimeError(f"no Mach-O files found inside {bundle}")
    return checked, sqlite_offenders, rust_offenders


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="explicit owned .app bundle to inspect")
    args = parser.parse_args()
    try:
        checked, sqlite_offenders, rust_offenders = check_bundle(args.bundle)
    except (OSError, RuntimeError, ValueError) as error:
        parser.exit(1, f"native symbol check failed: {error}\n")
    failures = []
    if sqlite_offenders:
        failures.append("bundled _sqlite3_open_v2 defined in "
                        + ", ".join(map(str, sqlite_offenders)))
    if rust_offenders:
        count = sum(len(symbols) for symbols in rust_offenders.values())
        paths = ", ".join(f"{path} ({len(symbols)})" for path, symbols in rust_offenders.items())
        failures.append(f"{count} private Rust exports (__R* or Rust-hashed __ZN*) in {paths}")
    if failures:
        parser.exit(1, "native symbol check failed: " + "; ".join(failures) + "\n")
    print(f"native symbol check passed: {checked} Mach-O files, no bundled SQLite or private Rust exports")


if __name__ == "__main__":
    main()
