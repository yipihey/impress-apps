#!/usr/bin/env bash
# scripts/new-capability.sh <name> — scaffold a new #[impress_service] capability
# (ADR-0033 D8).
#
# Generates crates/<name>-service: a trait with one demo verb (`echo`), a
# Tier-A style test that calls it through the linked inventory (the way MCP,
# the CLI and impel actually dispatch — not through the trait directly, which
# would not catch a macro-wiring mistake), an example surface that calls it,
# and the registration lines a new crate needs:
#
#   * a workspace member line in Cargo.toml,
#   * a workspace dependency line in Cargo.toml,
#   * a feature + optional dependency in crates/impress-capabilities/Cargo.toml
#     (ADR-0033 D4: the inventory is linked once, behind per-capability
#     features, so `full` links everything).
#
# That registration is for a DOMAIN capability. If <name> belongs in the
# ADR-0033 D7 standalone kit instead (store/layout/surface-shaped, no
# per-app domain core), it is registered differently: add <name>-service as
# a plain (non-optional, non-feature-gated) dependency directly in
# crates/impress-capabilities-kit/Cargo.toml, NOT in impress-capabilities —
# the kit crate has no per-capability feature list, it force-links its whole
# dependency set unconditionally (see that crate's module docs), and
# impress-capabilities only re-exports it behind its own `kit` feature. This
# script always registers the domain way below; undo that pair and add the
# kit-crate dependency instead when the capability is kit-grade.
#
# crates/impress-capabilities may not always have a [features] section to
# insert into (e.g. a mid-refactor checkout). This script does not fail on
# that: it prints exactly what to add by hand once the section exists.
#
# All edits are idempotent — running this script twice with the same name
# does not duplicate any line.
#
# Usage:
#   scripts/new-capability.sh <name>
#
# <name> must match ^[a-z][a-z0-9-]*$ and crates/<name>-service must not
# already exist. Fill in real verbs afterwards by following the pattern in
# crates/impress-layout-service/src/service.rs (many verbs, a store-backed
# impl) — this scaffold is deliberately the smallest thing that compiles and
# registers, per ADR-0033 D8: "the demo capability shipped with this ADR is
# its output, so the scaffold is proven by use."

set -euo pipefail

usage() {
    echo "usage: $(basename "$0") <name>" >&2
    echo "  <name> matches ^[a-z][a-z0-9-]*\$, e.g. \"signal\"" >&2
    exit 1
}

if [[ $# -ne 1 ]]; then
    usage
fi
NAME="$1"

if [[ ! "$NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "error: name must match ^[a-z][a-z0-9-]*\$, got: '$NAME'" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CRATE_NAME="${NAME}-service"
CRATE_DIR="crates/${CRATE_NAME}"

if [[ -e "$CRATE_DIR" ]]; then
    echo "error: $CRATE_DIR already exists — refusing to overwrite" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Derive the trait/impl/tool names the macro pipeline will produce.
#
# The tool name a verb registers under is kebab(<trait name>)_<kebab(method
# name)> (see crates/impress-service-macros/src/lib.rs, `kebab()` +
# `expand_method`; confirmed against `layout-service_*` in
# crates/impress-layout-service/src/lib.rs). Because <name> is already
# validated as lowercase-kebab, kebab(Pascal(<name>) + "Service") is exactly
# "<name>-service" — so the tool name is just "<name>-service_echo", no
# separate kebab pass needed here.
# ---------------------------------------------------------------------------

pascal_case() {
    local input="$1" out="" part first rest
    IFS='-' read -ra parts <<<"$input"
    for part in "${parts[@]}"; do
        first="$(printf '%s' "${part:0:1}" | tr '[:lower:]' '[:upper:]')"
        rest="${part:1}"
        out+="${first}${rest}"
    done
    printf '%s' "$out"
}

PASCAL="$(pascal_case "$NAME")"
TRAIT_NAME="${PASCAL}Service"
IMPL_NAME="Default${TRAIT_NAME}"
TOOL_NAME="${CRATE_NAME}_echo"

echo "Scaffolding ${CRATE_DIR}"
echo "  trait:  ${TRAIT_NAME}"
echo "  impl:   ${IMPL_NAME}"
echo "  verb:   ${TOOL_NAME}"
echo

mkdir -p "${CRATE_DIR}/src" "${CRATE_DIR}/examples"

# ---------------------------------------------------------------------------
# Write the crate files. Done in python3 (not a bash heredoc) because the
# generated Rust and JSON is full of `{`, `}`, `$` and backticks — exactly the
# characters an unquoted bash heredoc reinterprets.
# ---------------------------------------------------------------------------

python3 - "$NAME" "$CRATE_NAME" "$TRAIT_NAME" "$IMPL_NAME" "$TOOL_NAME" "$CRATE_DIR" <<'PYEOF'
import sys

name, crate_name, trait_name, impl_name, tool_name, crate_dir = sys.argv[1:7]

cargo_toml = """[package]
name = "__CRATE__"
description = "Scaffolded #[impress_service] capability (scripts/new-capability.sh): one demo verb, __TOOL__"
version.workspace = true
edition.workspace = true
license.workspace = true
repository.workspace = true

[dependencies]
impress-service-core = { workspace = true }
impress-service-macros = { workspace = true }
serde = { workspace = true, features = ["derive"] }
serde_json = { workspace = true }
schemars = { workspace = true }
async-trait = { workspace = true }
thiserror = { workspace = true }

[dev-dependencies]
tokio = { workspace = true, features = ["macros", "rt-multi-thread"] }
"""

lib_rs = '''//! `__TRAIT__` — a scaffolded #[impress_service] capability.
//!
//! Generated by `scripts/new-capability.sh __NAME__` (ADR-0033 D8). This is
//! the minimal shape a capability needs to become GUI-able: one trait, one
//! verb, one impl, the `impress_service_impl!` wiring, a Tier-A test that
//! calls the verb through the linked inventory — the way MCP, the CLI and
//! impel actually dispatch, which a direct trait call would not exercise —
//! and an example surface (`examples/__NAME__.surface.json`) that calls it
//! from a button.
//!
//! Replace `echo` with real verbs: add a method to the trait (with
//! `#[impress_method]`), implement it on `__IMPL__`, and add a matching
//! entry to the `impress_service_impl! { methods = [...] }` list below. For
//! a fuller worked example — many verbs, a store-backed impl — see
//! `crates/impress-layout-service/src/service.rs`. See also
//! `docs/agent-surfaces.md` for how a verb becomes callable from a surface.

use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// Result of the `echo` verb.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct EchoResult {
    pub reply: String,
}

/// __TRAIT__ — replace this doc comment with the capability's real
/// description. It is one of the two places a tool description can come
/// from (the other is a `///` inside `impress_service_impl! { methods = [...] }`);
/// see `impress-service-macros`' crate doc for the resolution order.
#[impress_service]
pub trait __TRAIT__: Send + Sync + 'static {
    /// Echo a message back to the caller, prefixed with `"echo: "`.
    #[impress_method]
    async fn echo(&self, message: String) -> EchoResult;
}

/// The default (and, until real verbs are added, only) implementation.
#[derive(Clone, Default)]
pub struct __IMPL__;

impl __IMPL__ {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait::async_trait]
impl __TRAIT__ for __IMPL__ {
    async fn echo(&self, message: String) -> EchoResult {
        EchoResult {
            reply: format!("echo: {message}"),
        }
    }
}

impress_service_impl! {
    service = __TRAIT__,
    impl = __IMPL__,
    instance = __IMPL__::new,
    methods = [
        /// Echo a message back to the caller, prefixed with `"echo: "`.
        echo(message: String) -> EchoResult,
    ],
}

#[cfg(test)]
mod tests {
    use impress_service_core::{runtime, McpToolDescriptor};
    use serde_json::json;

    /// Tier-A style: call the verb the way MCP, the CLI and impel actually
    /// do — by finding it in the linked inventory and running its handler —
    /// rather than calling the trait method directly, so this test would
    /// catch a macro-wiring mistake a direct call would miss.
    #[test]
    fn echo_round_trips_through_the_inventory() {
        let tool = McpToolDescriptor::iter()
            .find(|t| t.name == "__TOOL__")
            .unwrap_or_else(|| panic!("__TOOL__ should be registered in the inventory"));

        let result = runtime::block_on((tool.handler)(json!({ "message": "hi" })))
            .expect("echo should succeed");

        assert_eq!(result["reply"], json!("echo: hi"));
    }
}
'''

example_surface = '''{
  "surface": "1.0",
  "name": "__TRAIT__ (scaffold)",
  "state": { "message": "", "reply": "" },
  "root": {
    "column": [
      { "text": "# __TRAIT__" },
      {
        "field": { "text": {} },
        "label": "Message",
        "bind": "state.message"
      },
      {
        "button": {
          "label": "Echo",
          "on_click": [
            {
              "call": {
                "verb": "__TOOL__",
                "args": { "message": "{{state.message}}" },
                "into": "state.reply"
              }
            }
          ]
        }
      },
      { "text": "{{state.reply}}" }
    ]
  }
}
'''

def fill(template: str) -> str:
    return (
        template
        .replace("__CRATE__", crate_name)
        .replace("__NAME__", name)
        .replace("__TRAIT__", trait_name)
        .replace("__IMPL__", impl_name)
        .replace("__TOOL__", tool_name)
    )

with open(f"{crate_dir}/Cargo.toml", "w") as f:
    f.write(fill(cargo_toml))

with open(f"{crate_dir}/src/lib.rs", "w") as f:
    f.write(fill(lib_rs))

with open(f"{crate_dir}/examples/{name}.surface.json", "w") as f:
    f.write(fill(example_surface))

print(f"wrote {crate_dir}/Cargo.toml")
print(f"wrote {crate_dir}/src/lib.rs")
print(f"wrote {crate_dir}/examples/{name}.surface.json")
PYEOF

# ---------------------------------------------------------------------------
# Registration: workspace Cargo.toml (member + dependency line), then
# crates/impress-capabilities/Cargo.toml (feature + optional dependency,
# tolerantly — see header).
# ---------------------------------------------------------------------------

echo
python3 - "$NAME" "$CRATE_NAME" <<'PYEOF'
import sys

name, crate_name = sys.argv[1:3]


def upsert_after(text: str, anchor: str, line: str):
    """Insert `line` right after the first occurrence of `anchor` in `text`,
    unless `line` is already present anywhere in `text` (idempotent). Returns
    (new_text, status) where status is "added", "present", or "no-anchor"."""
    if line in text:
        return text, "present"
    idx = text.find(anchor)
    if idx == -1:
        return text, "no-anchor"
    insert_at = idx + len(anchor)
    return text[:insert_at] + line + text[insert_at:], "added"


# --- workspace Cargo.toml -------------------------------------------------

ws_path = "Cargo.toml"
with open(ws_path) as f:
    ws_text = f.read()

member_anchor = '    "crates/surface-demo-service",\n'
member_line = f'    "crates/{crate_name}",\n'
ws_text, status = upsert_after(ws_text, member_anchor, member_line)
if status == "added":
    print(f"Cargo.toml: added workspace member crates/{crate_name}")
elif status == "present":
    print(f"Cargo.toml: workspace member crates/{crate_name} already present")
else:
    print(
        "WARNING: could not find the crates/surface-demo-service member line "
        "in Cargo.toml to anchor on — add by hand:\n"
        f"  {member_line.strip()}"
    )

dep_anchor = 'surface-demo-service = { path = "crates/surface-demo-service" }\n'
dep_line = f'{crate_name} = {{ path = "crates/{crate_name}" }}\n'
ws_text, status = upsert_after(ws_text, dep_anchor, dep_line)
if status == "added":
    print(f"Cargo.toml: added workspace dependency {crate_name}")
elif status == "present":
    print(f"Cargo.toml: workspace dependency {crate_name} already present")
else:
    print(
        "WARNING: could not find the surface-demo-service workspace "
        "dependency line in Cargo.toml to anchor on — add by hand:\n"
        f"  {dep_line.strip()}"
    )

with open(ws_path, "w") as f:
    f.write(ws_text)

# --- crates/impress-capabilities/Cargo.toml (domain registration) --------
#
# This is the DOMAIN path (ADR-0033 D4: one feature + one optional
# dependency per capability, so `full` links everything). For a KIT-grade
# capability (ADR-0033 D7's standalone cut) the registration is different
# and this script does not do it: add `{crate_name} = {{ workspace = true }}`
# as a plain dependency directly in crates/impress-capabilities-kit/Cargo.toml
# instead (no feature, no `optional = true` — the kit crate force-links its
# whole dependency set unconditionally) and skip this section entirely.
#
# impress-capabilities may not always have [features] and [dependencies]
# sections to anchor on (e.g. a mid-refactor checkout). If either is
# missing, this does not edit the file at all — a feature entry with no
# dependency line (or vice versa) is a half-registration nobody asked for.
# Instead it prints exactly what to add by hand, once, covering both lines
# together.

cap_path = "crates/impress-capabilities/Cargo.toml"
with open(cap_path) as f:
    cap_text = f.read()

feature_line = f'{name} = ["dep:{crate_name}"]\n'
dep_line = f'{crate_name} = {{ workspace = true, optional = true }}\n'

if "[features]" not in cap_text or "[dependencies]" not in cap_text:
    print(
        f"NOTE: {cap_path} does not yet have both a [features] and a "
        "[dependencies] section to anchor on. Add the following by hand "
        "once it does (domain capability — for a kit-grade one, see the "
        "impress-capabilities-kit note in this script's header instead):\n"
    )
    print("  [features]")
    print(f"  {feature_line.strip()}")
    print()
    print("  [dependencies]")
    print(f"  {dep_line.strip()}")
else:
    cap_text, feature_status = upsert_after(cap_text, "[features]\n", feature_line)
    cap_text, dep_status = upsert_after(cap_text, "[dependencies]\n", dep_line)
    with open(cap_path, "w") as f:
        f.write(cap_text)
    for label, status in (("feature", feature_status), ("optional dependency", dep_status)):
        if status == "added":
            print(f"{cap_path}: added {label} '{name if label == 'feature' else crate_name}'")
        elif status == "present":
            print(f"{cap_path}: {label} '{name if label == 'feature' else crate_name}' already present")
PYEOF

echo
echo "Done. Next steps:"
echo "  1. Fill in real verbs in ${CRATE_DIR}/src/lib.rs"
echo "  2. export CARGO_TARGET_DIR=/home/user/impress-apps/target"
echo "  3. cargo test -p ${CRATE_NAME}"
echo "  4. If impress-capabilities printed manual steps above, apply them once"
echo "     that crate has a [features]/[dependencies] section."
echo "  5. If ${CRATE_NAME} is a KIT-grade capability (ADR-0033 D7 standalone"
echo "     cut), undo the impress-capabilities feature/dependency pair above"
echo "     and instead add '${CRATE_NAME} = { workspace = true }' as a plain"
echo "     dependency in crates/impress-capabilities-kit/Cargo.toml."
