#!/usr/bin/env python3
"""Generate docs/mcp-migration-ledger.md — the TypeScript → Rust MCP ledger.

Every tool the TypeScript server exposes, with either the Rust tool that already
covers it or a verdict (port / defer / drop) and a reason. Mechanical on the
left-hand side so nothing is missed: a ledger you hand-write is a ledger that
quietly loses rows, which is how "deferred" becomes "dropped".

Usage:
    python3 scripts/mcp-migration-ledger.py              # write the ledger
    python3 scripts/mcp-migration-ledger.py --check      # exit 1 if stale

Once packages/impress-mcp is deleted this can no longer run; the generated
markdown is then the historical record. That is intended.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TS_SRC = ROOT / "packages/impress-mcp/src"
LEDGER = ROOT / "docs/mcp-migration-ledger.md"

# --------------------------------------------------------------------------
# Verdicts
# --------------------------------------------------------------------------

# Whole modules whose fate is decided as a unit.
MODULE_VERDICT = {
    "impel": (
        "drop",
        "impel's own task API re-exposed over MCP. Dropping it means impel is "
        "driven from its UI and HTTP API rather than from an MCP client. "
        "`impel-core` already holds the task kernel, so an `impel-service` "
        "crate would regenerate this whole surface cheaply if it is missed.",
    ),
    "implore": ("port", "New `implore-service` over the existing `implore-core`."),
    "impart": ("port", "New `impart-service` over the existing `impart-core`."),
    "bridges": (
        "port",
        "Cross-app orchestration — the highest-value tools here and the one "
        "thing nothing else in the suite does. New `impress-bridges-service` "
        "composes the app services.",
    ),
    "shared-store": (
        "port",
        "Reimplemented in Rust over impress-core rather than a second SQLite "
        "reader (`better-sqlite3`). ~3 methods.",
    ),
    "prompts": (
        "drop",
        "MCP prompt templates. This is workflow judgement, which belongs in a "
        "skill file rather than an MCP server — retiring them avoids "
        "implementing the `prompts/*` protocol in Rust at all.",
    ),
}

# Per-tool deferrals within imbib / imprint.
DEFER = {
    **{
        t: "imbib sharing & collaboration — a feature area of its own; port when it is in use."
        for t in [
            "imbib_create_assignment", "imbib_delete_assignment",
            "imbib_list_assignments", "imbib_list_paper_assignments",
            "imbib_list_participants", "imbib_set_participant_permission",
            "imbib_share_library", "imbib_unshare_library", "imbib_sync_comments",
        ]
    },
    **{
        t: "Plotting belongs to implore. Porting it into imbib as well is how the drift started."
        for t in [
            "imbib_list_plot_specs", "imbib_render_plot",
            "imbib_save_plot_figure", "imbib_save_plot_spec",
        ]
    },
    **{
        t: "Plotting belongs to implore; imprint embeds the result rather than owning it."
        for t in [
            "imprint_list_plot_specs", "imprint_render_plot",
            "imprint_save_plot_figure", "imprint_save_plot_spec",
            "imprint_create_veusz_plot", "imprint_insert_veusz_plot",
            "imprint_list_veusz_plots", "imprint_open_veusz_plot",
            "imprint_render_veusz_plot",
        ]
    },
    **{
        t: "imprint AI author-tasks are still moving (Phases 2-4 pending); porting a moving surface invites a second rewrite."
        for t in [
            "imprint_accept_suggestion", "imprint_reject_suggestion",
            "imprint_suggest_citations", "imprint_list_tasks",
            "imprint_run_task", "imprint_get_operation",
            "imprint_wait_for_operation",
        ]
    },
}

# Equivalences the token heuristic gets wrong, judged by hand.
MANUAL_COVERED = {
    "imbib_add_papers": "imbib-library-service_import-papers",
    "imbib_search_library": "imbib-search-service_full-text-search",
    "imbib_collection_papers": "imbib-library-service_list-collection-members",
    "imbib_get_paper": "imbib-library-service_get-publication-detail",
    # `add-tag` applies a tag to a paper; `create-tag` defines one. The
    # add→create synonym picks the wrong half of that pair, in both directions.
    "imbib_add_tag": "imbib-tags-service_add-tag",
    "imbib_create_tag": "imbib-tags-service_create-tag",
    # Ported in the app-service phase; the token heuristic cannot see that
    # "sources" and "external" are the same idea.
    "imbib_search_sources": "imbib-app-service_search-sources",
    "imbib_get_library_activity": "imbib-app-service_recent-activity",
    # /api/search is already global across open documents, so the existing
    # search tool IS cross-document search. Building a second one nearly
    # recreated the duplication this migration exists to remove.
    "imprint_cross_document_search": "imprint-manuscript-service_search",
    "imprint_compile": "imprint-manuscript-service_compile-typst",
    "imprint_get_manuscript_sections": "imprint-manuscript-service_list-sections",
    "imprint_get_section_body": "imprint-manuscript-service_get-section",
}

# Heuristic matches that are wrong and must NOT be recorded as covered.
MANUAL_NOT_COVERED = {
    "imbib_delete_smart_searches",   # only get/create/list exist
    "imprint_insert_citation_in_section",
    # Adds a paper to a *library*; the heuristic reaches for the SciX-library
    # tools, which are a different thing entirely.
    "imbib_add_to_library",
}

# --------------------------------------------------------------------------
# Extraction
# --------------------------------------------------------------------------

TOOL_RE = re.compile(
    r'name:\s*"(?P<name>[a-z0-9_]+)"\s*,\s*'
    r'description:\s*(?P<desc>(?:"(?:[^"\\]|\\.)*"\s*\+?\s*)+)',
    re.MULTILINE,
)
STR_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')

NOISE = {"imbib", "imprint", "implore", "impart", "impel", "impress", "service",
         "undoable", "detail", "batch"}
SYN = {"papers": "publications", "paper": "publication", "add": "create",
       "new": "create", "edit": "update", "modify": "update", "find": "search",
       "query": "search", "toggle": "set", "mark": "set", "libraries": "library",
       "collections": "collection", "tags": "tag", "artifacts": "artifact",
       "annotations": "annotation", "comments": "comment", "documents": "document",
       "sections": "section", "searches": "search", "star": "starred",
       "unread": "read", "figures": "figure", "datasets": "dataset"}


def _norm(tokens):
    return {SYN.get(t, t) for t in tokens if t and t not in NOISE}


def ts_tools():
    out, seen = [], set()
    for path in sorted(TS_SRC.rglob("*.ts")):
        text = path.read_text(encoding="utf-8")
        module = path.parent.name if path.parent.name != "src" else "root"
        for m in TOOL_RE.finditer(text):
            name = m.group("name")
            if name in seen:
                continue
            seen.add(name)
            desc = "".join(s.group(1) for s in STR_RE.finditer(m.group("desc")))
            out.append({
                "name": name,
                "module": module,
                "description": " ".join(desc.replace('\\"', '"').split()),
            })
    return out


def rust_tools():
    """Ask the built Rust server for its inventory."""
    binary = ROOT / "target/debug/impress-mcp"
    if not binary.exists():
        sys.exit("build first: cargo build -p impress-mcp")
    req = ('{"jsonrpc":"2.0","id":1,"method":"initialize"}\n'
           '{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n')
    # --store-path away from the app group: opening it raises the macOS TCC
    # prompt, which blocks forever in a non-interactive run.
    proc = subprocess.run(
        [str(binary), "--store-path", "/nonexistent/ledger.sqlite"],
        input=req, capture_output=True, text=True, timeout=120,
        env={"IMBIB_BACKEND": "sqlite", "PATH": "/usr/bin:/bin"},
    )
    last = [l for l in proc.stdout.strip().split("\n") if l.strip()][-1]
    return [t["name"] for t in json.loads(last)["result"]["tools"]]


def match(ts_name, rs_names):
    """Best Rust tool for a TS tool, or None.

    Constrained to the same app. Without that guard the token heuristic happily
    maps `imprint_create_comment` onto `imbib-annotations-service_create-comment`
    — manuscript comments and paper annotations are different domains, and
    recording that as "covered" would delete the capability at cutover while the
    ledger claimed everything was fine.
    """
    app = ts_name.split("_", 1)[0]
    tt = _norm(ts_name.split("_"))
    best, score = None, 0.0
    for r in rs_names:
        # `impress_*` tools are cross-app by nature and are decided by module
        # verdict, not by matching.
        if app != "impress" and not r.startswith(f"{app}-"):
            continue
        rt = _norm(r.partition("_")[2].split("-"))
        if not tt or not rt:
            continue
        s = len(tt & rt) / len(tt | rt)
        if s > score:
            best, score = r, s
    return (best, score) if score >= 0.7 else (None, score)


# --------------------------------------------------------------------------
# Ledger
# --------------------------------------------------------------------------

def verdict_for(tool, rs_names):
    name, module = tool["name"], tool["module"]

    if name not in MANUAL_NOT_COVERED:
        if name in MANUAL_COVERED:
            return "covered", MANUAL_COVERED[name], "Already in the Rust inventory."
        hit, _ = match(name, rs_names)
        if hit:
            return "covered", hit, "Already in the Rust inventory."

    if name in DEFER:
        return "defer", "", DEFER[name]

    if module in MODULE_VERDICT:
        v, reason = MODULE_VERDICT[module]
        return v, "", reason

    return "port", "", "No Rust equivalent; needs a new `#[impress_method]`."


def build():
    ts = ts_tools()
    rs = rust_tools()
    rows = []
    for t in ts:
        v, equiv, reason = verdict_for(t, rs)
        rows.append({**t, "verdict": v, "rust": equiv, "reason": reason})

    counts = {}
    for r in rows:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1

    out = []
    out.append("# MCP migration ledger — TypeScript → Rust\n")
    out.append(
        "Generated by `scripts/mcp-migration-ledger.py`. Every tool "
        "`packages/impress-mcp` exposes, with either the Rust tool that already "
        "covers it or a verdict and a reason.\n"
    )
    out.append(
        "This is the backstop for the retirement: a row that is **deferred** is "
        "a decision, not an oversight, and cutover is not done until every "
        "**port** row resolves to a real Rust tool.\n"
    )
    out.append(f"- TypeScript tools: **{len(rows)}**")
    out.append(f"- Rust inventory today: **{len(rs)}**")
    for v in ("covered", "port", "defer", "drop"):
        out.append(f"- {v}: **{counts.get(v, 0)}**")
    out.append("")

    for module in sorted({r["module"] for r in rows}):
        group = [r for r in rows if r["module"] == module]
        out.append(f"\n## {module} ({len(group)})\n")
        out.append("| TypeScript tool | Verdict | Rust equivalent / reason |")
        out.append("|---|---|---|")
        for r in sorted(group, key=lambda x: (x["verdict"], x["name"])):
            detail = f"`{r['rust']}`" if r["rust"] else r["reason"]
            out.append(f"| `{r['name']}` | {r['verdict']} | {detail} |")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    text = build()
    if "--check" in sys.argv:
        current = LEDGER.read_text() if LEDGER.exists() else ""
        if current != text:
            sys.exit("ledger is stale — re-run scripts/mcp-migration-ledger.py")
        print("ledger up to date")
    else:
        LEDGER.parent.mkdir(parents=True, exist_ok=True)
        LEDGER.write_text(text)
        print(f"wrote {LEDGER.relative_to(ROOT)}")
