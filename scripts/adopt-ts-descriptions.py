#!/usr/bin/env python3
"""Adopt the TypeScript server's tool descriptions as Rust trait doc comments.

The single biggest asset in `packages/impress-mcp` is not its code — it is the
prose. Its descriptions cross-reference sibling tools, warn about destructive
operations, and say when *not* to reach for something. The Rust services mostly
carry no description at all, so their tools reach the model as
"Invoke ImbibLibraryService.import_papers".

Retiring the TypeScript server without moving that prose across would be a
straight downgrade in agent usability. This script does the move: for every
ledger row marked `covered`, it takes the TypeScript description and writes it
as a `///` comment on the corresponding Rust trait method, where
`#[impress_service]` now picks it up.

Idempotent: methods that already have a doc comment are left alone.

    python3 scripts/adopt-ts-descriptions.py --dry-run
    python3 scripts/adopt-ts-descriptions.py
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEDGER = ROOT / "docs/mcp-migration-ledger.md"
SERVICE_DIRS = [
    ROOT / "crates/imbib-service/src",
    ROOT / "crates/imprint-service/src",
]

sys.path.insert(0, str(ROOT / "scripts"))
from importlib import import_module  # noqa: E402

ledger_mod = import_module("mcp-migration-ledger".replace("-", "_")) if False else None


def ts_descriptions() -> dict[str, str]:
    """name -> description, straight from the TypeScript sources."""
    pattern = re.compile(
        r'name:\s*"(?P<name>[a-z0-9_]+)"\s*,\s*'
        r'description:\s*(?P<desc>(?:"(?:[^"\\]|\\.)*"\s*\+?\s*)+)',
        re.MULTILINE,
    )
    strings = re.compile(r'"((?:[^"\\]|\\.)*)"')
    out: dict[str, str] = {}
    for path in sorted((ROOT / "packages/impress-mcp/src").rglob("*.ts")):
        for m in pattern.finditer(path.read_text(encoding="utf-8")):
            if m.group("name") in out:
                continue
            desc = "".join(s.group(1) for s in strings.finditer(m.group("desc")))
            out[m.group("name")] = " ".join(desc.replace('\\"', '"').split())
    return out


def covered_pairs() -> list[tuple[str, str]]:
    """(ts_tool, rust_tool) for every ledger row marked covered."""
    row = re.compile(r"^\| `([a-z0-9_]+)` \| covered \| `([a-z0-9_-]+)` \|", re.MULTILINE)
    return row.findall(LEDGER.read_text(encoding="utf-8"))


def wrap(text: str, width: int = 76, indent: str = "    ") -> list[str]:
    words, lines, cur = text.split(), [], ""
    for w in words:
        candidate = f"{cur} {w}".strip()
        if len(candidate) + len(indent) + 4 > width and cur:
            lines.append(f"{indent}/// {cur}")
            cur = w
        else:
            cur = candidate
    if cur:
        lines.append(f"{indent}/// {cur}")
    return lines


def rewrite_cross_references(dry: bool) -> tuple[int, set[str]]:
    """Repoint tool names inside adopted doc comments at their Rust equivalents.

    The TypeScript prose is full of cross-references — "use imbib_recent_activity
    instead", "you do NOT need imbib_create_tag first". Those names stop existing
    at cutover, so left alone the descriptions would send the model after tools
    that are gone. Rewrite the ones the ledger can resolve; report the rest.
    """
    mapping = {ts: rust for ts, rust in covered_pairs()}
    token = re.compile(r"\b((?:imbib|imprint|implore|impart|impel|impress)_[a-z0-9_]+)\b")
    rewritten, unresolved = 0, set()

    for src_dir in SERVICE_DIRS:
        for path in sorted(src_dir.glob("*.rs")):
            text = path.read_text(encoding="utf-8")
            out_lines, changed = [], False
            for line in text.split("\n"):
                if line.strip().startswith("///"):
                    def sub(m: re.Match[str]) -> str:
                        nonlocal rewritten
                        hit = mapping.get(m.group(1))
                        if hit:
                            rewritten += 1
                            return f"`{hit}`"
                        unresolved.add(m.group(1))
                        return m.group(1)

                    new = token.sub(sub, line)
                    changed = changed or new != line
                    out_lines.append(new)
                else:
                    out_lines.append(line)
            if changed and not dry:
                path.write_text("\n".join(out_lines), encoding="utf-8")

    return rewritten, unresolved


def main() -> int:
    dry = "--dry-run" in sys.argv
    ts = ts_descriptions()

    # rust method ident -> description. The ledger names tools
    # (imbib-library-service_import-papers); the Rust source has import_papers.
    wanted: dict[str, str] = {}
    for ts_name, rust_tool in covered_pairs():
        desc = ts.get(ts_name)
        if not desc:
            continue
        method = rust_tool.partition("_")[2].replace("-", "_")
        # First mapping wins; ledger rows are stable-sorted by verdict then name.
        wanted.setdefault(method, desc)

    applied, skipped = 0, 0
    for src_dir in SERVICE_DIRS:
        for path in sorted(src_dir.glob("*.rs")):
            text = path.read_text(encoding="utf-8")
            lines = text.split("\n")
            out: list[str] = []
            changed = False
            for i, line in enumerate(lines):
                stripped = line.strip()
                if stripped == "#[impress_method]":
                    # The method ident is on the next non-empty line.
                    nxt = next(
                        (lines[j] for j in range(i + 1, len(lines)) if lines[j].strip()),
                        "",
                    )
                    m = re.search(r"async fn (\w+)", nxt)
                    prev = next(
                        (out[k] for k in range(len(out) - 1, -1, -1) if out[k].strip()),
                        "",
                    )
                    if m and not prev.strip().startswith("///"):
                        desc = wanted.get(m.group(1))
                        if desc:
                            indent = line[: len(line) - len(line.lstrip())]
                            out.extend(wrap(desc, indent=indent))
                            applied += 1
                            changed = True
                        else:
                            skipped += 1
                out.append(line)
            if changed and not dry:
                path.write_text("\n".join(out), encoding="utf-8")

    rewritten, unresolved = rewrite_cross_references(dry)

    print(f"descriptions adopted: {applied}")
    print(f"methods still undocumented: {skipped}")
    print(f"cross-references repointed at Rust tools: {rewritten}")
    if unresolved:
        print(f"cross-references left unresolved: {len(unresolved)}")
        for name in sorted(unresolved):
            print(f"  {name}  (no covered ledger row — port it, then re-run)")
    if dry:
        print("(dry run — nothing written)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
