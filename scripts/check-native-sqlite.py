#!/usr/bin/env python3
"""Refuse a hosted app bundle that defines its own SQLite implementation.

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


def check_bundle(bundle: Path) -> tuple[int, list[Path]]:
    bundle = bundle.resolve(strict=True)
    if not bundle.is_dir() or bundle.suffix != ".app":
        raise ValueError(f"expected one built .app bundle: {bundle}")

    seen: set[Path] = set()
    checked = 0
    offenders: list[Path] = []
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
                offenders.append(target.relative_to(bundle))
    if checked == 0:
        raise RuntimeError(f"no Mach-O files found inside {bundle}")
    return checked, offenders


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="explicit owned .app bundle to inspect")
    args = parser.parse_args()
    try:
        checked, offenders = check_bundle(args.bundle)
    except (OSError, RuntimeError, ValueError) as error:
        parser.exit(1, f"native SQLite check failed: {error}\n")
    if offenders:
        parser.exit(1, "native SQLite check failed: bundled _sqlite3_open_v2 defined in "
                    + ", ".join(map(str, offenders)) + "\n")
    print(f"native SQLite check passed: {checked} Mach-O files, no bundled _sqlite3_open_v2")


if __name__ == "__main__":
    main()
