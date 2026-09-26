//! The one verb descriptor (ADR-0034 D1, plan-verb-pipeline P1).
//!
//! Every `#[impress_method]` expands to exactly one `static`
//! [`VerbDescriptor`]; [`McpToolDescriptor`](crate::McpToolDescriptor) and
//! [`CliSubcommand`](crate::CliSubcommand) are projections of it (each keeps
//! the fields its readers use and a `verb` pointer back), so the inventory
//! `submit!`s and their readers compile unchanged while every interface reads
//! the same record.
//!
//! Derived over declared: the output schema comes from the return type (the
//! macro adds the `JsonSchema` bound), the group from the service, the name
//! from the identifiers. What is declared — `safety`, `since`, examples — is
//! declared once per service with per-method exceptions, and every declared
//! field has a test over the linked inventory
//! (`crates/impress-capabilities/tests/descriptor.rs`) that fails when it is
//! missing or disagrees with the committed table (`docs/verb-safety.md`).

use serde_json::{json, Value};

use crate::ServiceFuture;

/// What a verb does to the world, in the vocabulary of the safety table
/// (plan-auto-gui-and-self-docs.md table 4, appendix A4).
///
/// The class is the *worst* thing the verb can do: a verb that deletes rows
/// is `Destructive` even when it usually only reads; a verb whose default
/// implementation refuses and whose HTTP backend reaches a running app, the
/// network, a device or a subprocess is `External`, whatever it does there.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SafetyClass {
    /// Reads the store or computes; changes nothing an undo would need.
    ReadOnly,
    /// Writes rows or files in a way the suite can account for (an
    /// operation row, an undo ring, a revision).
    Mutating,
    /// Deletes or overwrites with no inverse the service offers.
    Destructive,
    /// Leaves the process: a running app over HTTP, the network, a device,
    /// a subprocess, an AI provider. What happens there is not the store's.
    External,
}

impl SafetyClass {
    /// Every class, in table order.
    pub const ALL: [SafetyClass; 4] = [
        SafetyClass::ReadOnly,
        SafetyClass::Mutating,
        SafetyClass::Destructive,
        SafetyClass::External,
    ];

    /// The spelling used in `impress_service_impl! { safety = … }`,
    /// `#[impress_method(safety = …)]` and `docs/verb-safety.md`.
    pub const fn as_str(self) -> &'static str {
        match self {
            SafetyClass::ReadOnly => "read_only",
            SafetyClass::Mutating => "mutating",
            SafetyClass::Destructive => "destructive",
            SafetyClass::External => "external",
        }
    }

    /// Parse the table spelling (`read_only`, also accepting `read-only`).
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim() {
            "read_only" | "read-only" => Some(SafetyClass::ReadOnly),
            "mutating" => Some(SafetyClass::Mutating),
            "destructive" => Some(SafetyClass::Destructive),
            "external" => Some(SafetyClass::External),
            _ => None,
        }
    }

    /// A read-only verb is idempotent by construction; anything else must
    /// say so.
    pub const fn default_idempotent(self) -> bool {
        matches!(self, SafetyClass::ReadOnly)
    }
}

impl std::fmt::Display for SafetyClass {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The safety facts a policy layer (ADR-0034 D3) and an MCP client read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Safety {
    pub class: SafetyClass,
    /// Calling the verb twice with the same arguments leaves the world as
    /// one call would. Defaults to `class.default_idempotent()`; a mutating
    /// verb that is (a `set-*`, an upsert) declares `idempotent = true`.
    pub idempotent: bool,
}

/// A named example call, declared beside the method with
/// `#[impress_example(name = "…", args = r#"{…}"#, expect = r#"{…}"#)]`.
///
/// P1 defines the attribute and the storage; ADR-0035 G3 populates the
/// inventory and runs each example in Tier A. `args` and `expect` are JSON
/// text (the macro checks they parse) so the static needs no allocation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Example {
    pub name: &'static str,
    /// The argument object, as JSON text.
    pub args: &'static str,
    /// The expected result shape, as JSON text, when the example states one.
    pub expect: Option<&'static str>,
}

impl Example {
    /// The argument object, parsed.
    pub fn args_value(&self) -> Value {
        serde_json::from_str(self.args).unwrap_or(Value::Null)
    }
}

/// A verb's retirement notice (ADR-0034 D5, filled by P3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Deprecation {
    /// The version the verb was deprecated in.
    pub since: &'static str,
    /// The verb that replaces it, when one does.
    pub alias_of: Option<&'static str>,
    pub note: &'static str,
}

/// Where a descriptor comes from (ADR-0034 D5, D7; P3 and P8 add variants).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// Generated by `impress_service_impl!` and linked into this binary.
    Linked,
}

/// Per-method facts `#[impress_service]` captures from the trait for
/// `impress_service_impl!` to resolve at compile time: the doc comment, the
/// safety override and the examples. One table per trait, a `static` so the
/// generated descriptor can point into it.
#[derive(Debug)]
pub struct MethodMeta {
    /// The Rust method identifier.
    pub name: &'static str,
    /// The joined `///` comment (never empty; the macro refuses an
    /// undocumented method).
    pub doc: &'static str,
    /// `#[impress_method(safety = …)]`, when the method departs from the
    /// service's default.
    pub safety: Option<SafetyClass>,
    /// `#[impress_method(idempotent = …)]`, when declared.
    pub idempotent: Option<bool>,
    pub examples: &'static [Example],
}

/// Find a method's captured facts by identifier. `const` because
/// `inventory::submit!` builds a `static`.
pub const fn method_meta(
    table: &'static [MethodMeta],
    method: &str,
) -> Option<&'static MethodMeta> {
    let mut i = 0;
    while i < table.len() {
        if crate::const_str_eq(table[i].name, method) {
            return Some(&table[i]);
        }
        i += 1;
    }
    None
}

/// The safety class for a method: its own declaration, else the service's
/// default.
pub const fn resolve_safety_class(
    table: &'static [MethodMeta],
    method: &str,
    service_default: SafetyClass,
) -> SafetyClass {
    match method_meta(table, method) {
        Some(MethodMeta {
            safety: Some(class),
            ..
        }) => *class,
        _ => service_default,
    }
}

/// Idempotency for a method: its own declaration, else the class's default.
pub const fn resolve_idempotent(
    table: &'static [MethodMeta],
    method: &str,
    class: SafetyClass,
) -> bool {
    match method_meta(table, method) {
        Some(MethodMeta {
            idempotent: Some(flag),
            ..
        }) => *flag,
        _ => class.default_idempotent(),
    }
}

/// The examples declared on a method (empty until G3 writes them).
pub const fn resolve_examples(table: &'static [MethodMeta], method: &str) -> &'static [Example] {
    match method_meta(table, method) {
        Some(meta) => meta.examples,
        None => &[],
    }
}

/// One verb, as every interface sees it.
///
/// Field by field, where it comes from:
/// - `name`, `service`, `method`: the identifiers (derived);
/// - `description`: the trait method's doc (derived; refused when empty);
/// - `input_schema`: `schema_for!` of the generated args struct (derived);
/// - `output_schema`: `schema_for!` of the return type (derived — the bound
///   is why every result type derives `JsonSchema`);
/// - `safety`: the service's `safety = …` default with the method's
///   `#[impress_method(safety = …)]` exception (declared; checked against
///   `docs/verb-safety.md`);
/// - `since`: the service's `since = "…"` (declared; checked non-empty);
/// - `deprecated`, `aliases`: P3's lifecycle fields, empty until then;
/// - `examples`: `#[impress_example]` on the method (declared; G3 fills);
/// - `strict`: the service's `strict_args` (declared);
/// - `source`, `handler`: how the verb runs.
pub struct VerbDescriptor {
    /// The qualified tool name, `<service>_<method>` in kebab case — the MCP
    /// tool name, the CLI's fallback spelling and the name a surface uses.
    pub name: &'static str,
    /// The service in kebab case (`imbib-library-service`): the group.
    pub service: &'static str,
    /// The method in kebab case (`delete-publications-undoable`): the CLI's
    /// short spelling.
    pub method: &'static str,
    pub description: &'static str,
    pub input_schema: fn() -> Value,
    pub output_schema: fn() -> Value,
    pub safety: Safety,
    pub since: &'static str,
    pub deprecated: Option<Deprecation>,
    pub aliases: &'static [&'static str],
    pub examples: &'static [Example],
    /// `impress_service_impl! { strict_args = true }`: an argument the schema
    /// does not name is refused `invalid-argument`.
    pub strict: bool,
    pub source: Source,
    pub handler: fn(Value) -> ServiceFuture,
}

impl VerbDescriptor {
    /// Every verb linked into this binary, in inventory order.
    pub fn iter() -> impl Iterator<Item = &'static VerbDescriptor> {
        crate::McpToolDescriptor::iter().map(|d| d.verb)
    }

    /// Look one up by its qualified name.
    pub fn find(name: &str) -> Option<&'static VerbDescriptor> {
        Self::iter().find(|v| v.name == name)
    }

    /// The MCP `annotations` object (MCP 2025-03-26 tool annotations), read
    /// off the safety class:
    /// - `readOnlyHint`: the class is `read_only`;
    /// - `destructiveHint`: the class is `destructive` — or `external`, since
    ///   what an external call does is not the store's to promise (the
    ///   protocol's own default is `true`, so this is the conservative
    ///   reading, not a new claim);
    /// - `idempotentHint`: `safety.idempotent`;
    /// - `openWorldHint`: the class is `external`.
    pub fn mcp_annotations(&self) -> Value {
        let class = self.safety.class;
        json!({
            "readOnlyHint": class == SafetyClass::ReadOnly,
            "destructiveHint": matches!(class, SafetyClass::Destructive | SafetyClass::External),
            "idempotentHint": self.safety.idempotent,
            "openWorldHint": class == SafetyClass::External,
        })
    }
}

impl std::fmt::Debug for VerbDescriptor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VerbDescriptor")
            .field("name", &self.name)
            .field("description", &self.description)
            .field("safety", &self.safety)
            .field("since", &self.since)
            .field("strict", &self.strict)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    static TABLE: [MethodMeta; 2] = [
        MethodMeta {
            name: "delete",
            doc: "Delete it.",
            safety: Some(SafetyClass::Destructive),
            idempotent: None,
            examples: &[Example {
                name: "one",
                args: r#"{"id": "x"}"#,
                expect: None,
            }],
        },
        MethodMeta {
            name: "set_flag",
            doc: "Set it.",
            safety: None,
            idempotent: Some(true),
            examples: &[],
        },
    ];

    #[test]
    fn a_method_override_beats_the_service_default() {
        assert_eq!(
            resolve_safety_class(&TABLE, "delete", SafetyClass::Mutating),
            SafetyClass::Destructive
        );
        assert_eq!(
            resolve_safety_class(&TABLE, "set_flag", SafetyClass::Mutating),
            SafetyClass::Mutating
        );
        assert_eq!(
            resolve_safety_class(&TABLE, "missing", SafetyClass::ReadOnly),
            SafetyClass::ReadOnly
        );
    }

    #[test]
    fn idempotency_defaults_from_the_class_unless_declared() {
        assert!(!resolve_idempotent(
            &TABLE,
            "delete",
            SafetyClass::Destructive
        ));
        assert!(resolve_idempotent(
            &TABLE,
            "set_flag",
            SafetyClass::Mutating
        ));
        assert!(resolve_idempotent(&TABLE, "missing", SafetyClass::ReadOnly));
        assert!(!resolve_idempotent(
            &TABLE,
            "missing",
            SafetyClass::Mutating
        ));
    }

    #[test]
    fn examples_resolve_per_method() {
        assert_eq!(resolve_examples(&TABLE, "delete").len(), 1);
        assert_eq!(
            resolve_examples(&TABLE, "delete")[0].args_value()["id"],
            "x"
        );
        assert!(resolve_examples(&TABLE, "set_flag").is_empty());
        assert!(resolve_examples(&TABLE, "missing").is_empty());
    }

    #[test]
    fn class_spelling_round_trips() {
        for class in SafetyClass::ALL {
            assert_eq!(SafetyClass::parse(class.as_str()), Some(class));
        }
        assert_eq!(SafetyClass::parse("read-only"), Some(SafetyClass::ReadOnly));
        assert_eq!(SafetyClass::parse("nope"), None);
    }

    fn schema() -> Value {
        json!({})
    }
    fn handler(_: Value) -> ServiceFuture {
        Box::pin(async { Ok(Value::Null) })
    }

    #[test]
    fn annotations_follow_the_class() {
        let mut verb = VerbDescriptor {
            name: "t-service_x",
            service: "t-service",
            method: "x",
            description: "d",
            input_schema: schema,
            output_schema: schema,
            safety: Safety {
                class: SafetyClass::ReadOnly,
                idempotent: true,
            },
            since: "0.1.0",
            deprecated: None,
            aliases: &[],
            examples: &[],
            strict: false,
            source: Source::Linked,
            handler,
        };
        assert_eq!(
            verb.mcp_annotations(),
            json!({"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false})
        );
        verb.safety = Safety {
            class: SafetyClass::Destructive,
            idempotent: false,
        };
        assert_eq!(
            verb.mcp_annotations(),
            json!({"readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false})
        );
        verb.safety.class = SafetyClass::External;
        assert_eq!(
            verb.mcp_annotations(),
            json!({"readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true})
        );
        verb.safety.class = SafetyClass::Mutating;
        assert_eq!(
            verb.mcp_annotations(),
            json!({"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false})
        );
    }
}
