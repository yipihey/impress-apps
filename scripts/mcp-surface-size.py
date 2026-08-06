#!/usr/bin/env python3
"""Measure what an MCP server actually costs a client (ADR-0024 WP S0).

Drives a server over stdio — `initialize`, `tools/list` — and sizes the reply:
tool count, schema bytes, and a token estimate, broken down by namespace. It
speaks plain MCP, so it works on any server, not only this one; the comparisons
in ADR-0024 against `lilook` and `scix` were taken with it.

Why a script and not a test: the number that matters is what a *client* is
handed, which is the shipped binary's `tools/list` after reachability gating and
after the surface projection. Nothing inside the crate can see that. ADR-0024
chose the grouped projection on measurements from this script, so it lives beside
the decision it justified — a token budget nobody can reproduce is a number
somebody typed.

Usage:
    python3 scripts/mcp-surface-size.py target/debug/impress-mcp
    python3 scripts/mcp-surface-size.py target/debug/impress-mcp --env IMPRESS_MCP_SURFACE=flat
    python3 scripts/mcp-surface-size.py --compare target/debug/impress-mcp
    python3 scripts/mcp-surface-size.py npx -- -y some-mcp-server@latest mcp

Token estimates are chars/4 — good enough to size a budget, not a billing
figure.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

CHARS_PER_TOKEN = 4


def list_tools(argv: list[str], env_overrides: dict[str, str]) -> list[dict]:
    """Run the MCP handshake against `argv` and return its tool descriptors."""
    env = dict(os.environ, **env_overrides)
    proc = subprocess.Popen(
        argv,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=env,
        text=True,
        bufsize=1,
    )

    def send(obj: dict) -> None:
        assert proc.stdin is not None
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    send({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "mcp-surface-size", "version": "1"},
        },
    })

    tools: list[dict] | None = None
    assert proc.stdout is not None
    for line in proc.stdout:
        if not line.strip().startswith("{"):
            continue  # servers log to stdout more often than they should
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("id") == 1:
            send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        if msg.get("id") == 2:
            tools = msg.get("result", {}).get("tools")
            break
    proc.kill()

    if tools is None:
        sys.exit(f"no tools/list response from {' '.join(argv)}")
    return tools


def report(label: str, tools: list[dict], by_namespace: bool = True) -> int:
    """Print a size report. Returns the token estimate."""
    total = len(json.dumps(tools))
    tokens = total // CHARS_PER_TOKEN
    print(f"{label}: {len(tools)} tools, {total} chars, ~{tokens} tokens")

    if not by_namespace:
        return tokens

    groups: dict[str, dict[str, int]] = {}
    for tool in tools:
        namespace = tool["name"].split("_", 1)[0]
        group = groups.setdefault(namespace, {"n": 0, "chars": 0, "desc": 0})
        group["n"] += 1
        group["chars"] += len(json.dumps(tool))
        group["desc"] += len(tool.get("description") or "")

    print(f"  {'tools':>5} {'chars':>7} {'tokens':>7} {'desc':>5}  namespace")
    for namespace, group in sorted(groups.items(), key=lambda kv: -kv[1]["chars"]):
        share = 100 * group["desc"] // max(group["chars"], 1)
        print(
            f"  {group['n']:>5} {group['chars']:>7} "
            f"{group['chars'] // CHARS_PER_TOKEN:>7} {share:>4}%  {namespace}"
        )
    return tokens


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", help="server executable")
    parser.add_argument("args", nargs="*", help="arguments passed to the server")
    parser.add_argument("--env", action="append", default=[], metavar="K=V",
                        help="environment override, repeatable")
    parser.add_argument("--compare", action="store_true",
                        help="size both impress projections and report the saving")
    opts = parser.parse_args()

    overrides = dict(kv.split("=", 1) for kv in opts.env)
    argv = [opts.command, *opts.args]

    if not opts.compare:
        report(os.path.basename(opts.command), list_tools(argv, overrides))
        return

    flat = report("flat   ", list_tools(argv, {**overrides, "IMPRESS_MCP_SURFACE": "flat"}))
    print()
    grouped = report("grouped", list_tools(argv, {**overrides, "IMPRESS_MCP_SURFACE": "grouped"}))
    if flat:
        print(f"\ngrouped costs {100 * grouped // flat}% of flat "
              f"({flat - grouped} tokens saved per request)")


if __name__ == "__main__":
    main()
