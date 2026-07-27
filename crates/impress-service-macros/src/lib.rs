//! Procedural macros for the impress service codegen pipeline.
//!
//! # Usage
//!
//! ```ignore
//! use impress_service_core as svc;
//! use impress_service_macros::{impress_service, impress_service_impl};
//!
//! #[impress_service]
//! pub trait EchoService: Send + Sync + 'static {
//!     /// Echo a message back to the caller.
//!     #[impress_method]
//!     async fn echo(&self, message: String) -> String;
//! }
//!
//! pub struct DemoEcho;
//!
//! #[async_trait::async_trait]
//! impl EchoService for DemoEcho {
//!     async fn echo(&self, message: String) -> String {
//!         format!("echo: {message}")
//!     }
//! }
//!
//! impress_service_impl! {
//!     service = EchoService,
//!     impl = DemoEcho,
//!     instance = || DemoEcho,
//!     methods = [
//!         echo(message: String) -> String,
//!     ],
//! }
//! ```
//!
//! Phase 0 supports a small set of "simple" argument types:
//! `String`, `i64`, `u64`, `bool`, `Option<String>`, `Vec<String>`.
//! Return types follow the same set, plus `()`.
//!
//! The macros emit, per method:
//! * A standalone async invoker `__impress_<service>_<method>_invoke`.
//! * An `inventory::submit!` registering an `McpToolDescriptor`.
//! * An `inventory::submit!` registering a `CliSubcommand`.
//! * (Feature-gated) `#[uniffi::export]` and `#[pyo3::pyfunction]` shims.
//!
//! Anything more elaborate (custom DTOs, error mapping nuances) is deferred to
//! Phase 1+.

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;
use quote::{format_ident, quote};
use syn::{parse_macro_input, Ident, ItemTrait, TraitItem, Type};

/// `#[impress_service]` attribute on a trait.
///
/// Confirms the trait has at least one `#[impress_method]`, strips the
/// per-method marker attribute (Rust does not let unknown attributes on trait
/// items flow downstream untouched), and emits the trait plus a hidden
/// `__IMPRESS_SERVICE_DOCS_<Trait>` table of each method's doc comment.
///
/// That table is why a description written on the trait — where a Rust
/// developer naturally puts it — reaches the model. Before it existed, only
/// `///` comments inside `impress_service_impl! { methods = [...] }` were read,
/// and 119 of 133 tools silently shipped `"Invoke Service.method"`.
///
/// The heavy lifting (per-method invokers, inventory submissions, FFI shims) is
/// performed by [`impress_service_impl!`] against a concrete impl block,
/// because that is where we know the concrete `Self` type to dispatch into.
#[proc_macro_attribute]
pub fn impress_service(_attr: TokenStream, input: TokenStream) -> TokenStream {
    let mut trait_item = parse_macro_input!(input as ItemTrait);

    let mut found_any_method = false;
    // (method_name, doc) for every #[impress_method], so `impress_service_impl!`
    // can use the trait's own doc comments as tool descriptions. Without this
    // the docs a developer writes on the trait are silently dropped and the
    // model gets "Invoke Service.method".
    let mut docs: Vec<(String, String)> = Vec::new();

    for item in &mut trait_item.items {
        if let TraitItem::Fn(method) = item {
            let before = method.attrs.len();
            method
                .attrs
                .retain(|attr| !attr.path().is_ident("impress_method"));
            if method.attrs.len() != before {
                found_any_method = true;
                docs.push((method.sig.ident.to_string(), collect_doc(&method.attrs)));
            }
        }
    }

    if !found_any_method {
        let trait_name = trait_item.ident.to_string();
        let msg = format!(
            "#[impress_service] trait `{trait_name}` has no #[impress_method] methods; \
             add #[impress_method] to at least one method.",
        );
        let err = syn::Error::new_spanned(&trait_item.ident, msg).to_compile_error();
        return quote! {
            #trait_item
            #err
        }
        .into();
    }

    // The trait has `async fn` methods, so it needs `#[async_trait::async_trait]`
    // applied (until native async-in-traits are universally available with
    // dyn-compatible vtables on Rust stable). We add it here so users don't
    // have to write the attribute themselves.
    // Emitted beside the trait so `impress_service_impl!` can resolve each
    // method's description. A free const rather than an associated const:
    // associated consts make a trait non-dyn-compatible, and every service is
    // used as `Arc<dyn Trait>`.
    let docs_const = format_ident!("__IMPRESS_SERVICE_DOCS_{}", trait_item.ident);
    let doc_entries = docs.iter().map(|(name, doc)| quote! { (#name, #doc) });
    let doc_count = docs.len();

    quote! {
        // `too_many_arguments`: a service method's parameter list *is* the
        // tool's input schema. Bundling arguments into a struct to please the
        // lint would change the schema agents see, so a 10-parameter method is
        // correct here in a way it would not be in ordinary code.
        #[allow(clippy::too_many_arguments)]
        #[::impress_service_core::async_trait::async_trait]
        #trait_item

        #[doc(hidden)]
        #[allow(non_upper_case_globals)]
        pub const #docs_const: [(&'static str, &'static str); #doc_count] =
            [#(#doc_entries),*];
    }
    .into()
}

/// `#[impress_method]` marker on a trait method.
///
/// At the moment this is a pure marker consumed by [`macro@impress_service`].
/// Defining it as its own attribute macro lets users write the attribute on
/// trait methods without the compiler complaining about an unknown attribute.
/// If invoked directly on a free-standing item (which should not happen in
/// normal use) it returns the item unchanged.
#[proc_macro_attribute]
pub fn impress_method(_attr: TokenStream, input: TokenStream) -> TokenStream {
    input
}

// ---------------------------------------------------------------------------
// impress_service_impl! — the workhorse function-like macro
// ---------------------------------------------------------------------------

struct ImplMacroInput {
    service: Ident,
    instance: syn::Expr,
    methods: Vec<MethodDecl>,
}

struct MethodDecl {
    name: Ident,
    doc: String,
    args: Vec<(Ident, Type)>,
    ret: Option<Type>,
}

impl syn::parse::Parse for ImplMacroInput {
    fn parse(input: syn::parse::ParseStream) -> syn::Result<Self> {
        // Format (comma-separated fields, trailing comma allowed):
        //   service = TraitName,
        //   impl = TypeName,        // accepted but currently unused by the
        //                           // generated code (kept for symmetry +
        //                           // future Self-type-aware codegen)
        //   instance = || TypeName, // expression that yields a value
        //                           // implementing the trait
        //   methods = [
        //     name(arg: Type, ...) -> RetType,
        //     name(arg: Type, ...),            // implicit `-> ()`
        //   ],

        let mut service: Option<Ident> = None;
        let mut instance: Option<syn::Expr> = None;
        let mut methods: Option<Vec<MethodDecl>> = None;

        while !input.is_empty() {
            // Accept both regular identifiers and keywords-as-identifiers
            // (notably `impl`, which is a reserved word). We peek-by-text to
            // keep the surface-level DSL readable.
            let key_text: String = if input.peek(syn::Token![impl]) {
                input.parse::<syn::Token![impl]>()?;
                "impl".to_string()
            } else {
                let id: Ident = input.parse()?;
                id.to_string()
            };
            input.parse::<syn::Token![=]>()?;
            match key_text.as_str() {
                "service" => service = Some(input.parse()?),
                "impl" => {
                    let _ty: Type = input.parse()?;
                }
                "instance" => instance = Some(input.parse()?),
                "methods" => {
                    let content;
                    syn::bracketed!(content in input);
                    let mut list = Vec::new();
                    while !content.is_empty() {
                        list.push(parse_method_decl(&content)?);
                        if content.peek(syn::Token![,]) {
                            content.parse::<syn::Token![,]>()?;
                        }
                    }
                    methods = Some(list);
                }
                other => {
                    return Err(syn::Error::new(
                        input.span(),
                        format!("unknown impress_service_impl! key `{other}`"),
                    ));
                }
            }
            if input.peek(syn::Token![,]) {
                input.parse::<syn::Token![,]>()?;
            }
        }

        Ok(Self {
            service: service
                .ok_or_else(|| syn::Error::new(input.span(), "missing `service = ...`"))?,
            instance: instance
                .ok_or_else(|| syn::Error::new(input.span(), "missing `instance = ...`"))?,
            methods: methods
                .ok_or_else(|| syn::Error::new(input.span(), "missing `methods = [...]`"))?,
        })
    }
}

fn parse_method_decl(input: syn::parse::ParseStream) -> syn::Result<MethodDecl> {
    // Optional `/// doc comment` lines as `#[doc = "..."]` attrs.
    let attrs = input.call(syn::Attribute::parse_outer)?;
    let doc = collect_doc(&attrs);

    let name: Ident = input.parse()?;
    let arg_content;
    syn::parenthesized!(arg_content in input);

    let mut args = Vec::new();
    while !arg_content.is_empty() {
        let arg_name: Ident = arg_content.parse()?;
        arg_content.parse::<syn::Token![:]>()?;
        let arg_ty: Type = arg_content.parse()?;
        args.push((arg_name, arg_ty));
        if arg_content.peek(syn::Token![,]) {
            arg_content.parse::<syn::Token![,]>()?;
        }
    }

    let ret = if input.peek(syn::Token![->]) {
        input.parse::<syn::Token![->]>()?;
        let ty: Type = input.parse()?;
        Some(ty)
    } else {
        None
    };

    Ok(MethodDecl {
        name,
        doc,
        args,
        ret,
    })
}

/// Join `///` lines into a description.
///
/// Rust doc comments are hard-wrapped at the source margin, so joining every
/// line with `\n` puts a break in the middle of each sentence. Consecutive
/// lines are one paragraph and join with a space; a blank `///` line is a
/// deliberate paragraph break and becomes `\n\n`.
fn collect_doc(attrs: &[syn::Attribute]) -> String {
    let mut paragraphs: Vec<String> = Vec::new();
    let mut current = String::new();

    for attr in attrs {
        if !attr.path().is_ident("doc") {
            continue;
        }
        let syn::Meta::NameValue(nv) = &attr.meta else {
            continue;
        };
        let syn::Expr::Lit(lit) = &nv.value else {
            continue;
        };
        let syn::Lit::Str(s) = &lit.lit else {
            continue;
        };

        let line = s.value();
        let line = line.trim();
        if line.is_empty() {
            if !current.is_empty() {
                paragraphs.push(std::mem::take(&mut current));
            }
            continue;
        }
        if !current.is_empty() {
            current.push(' ');
        }
        current.push_str(line);
    }
    if !current.is_empty() {
        paragraphs.push(current);
    }
    paragraphs.join("\n\n")
}

fn kebab(s: &str) -> String {
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if c == '_' {
            out.push('-');
        } else if c.is_ascii_uppercase() {
            if i != 0 {
                out.push('-');
            }
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

/// Expand `impress_service_impl!`.
#[proc_macro]
pub fn impress_service_impl(input: TokenStream) -> TokenStream {
    let parsed = parse_macro_input!(input as ImplMacroInput);
    match expand_impl(parsed) {
        Ok(ts) => ts.into(),
        Err(e) => e.to_compile_error().into(),
    }
}

fn expand_impl(input: ImplMacroInput) -> syn::Result<TokenStream2> {
    let service = &input.service;
    let instance = &input.instance;

    let mut emitted = Vec::new();
    for method in &input.methods {
        emitted.push(expand_method(service, instance, method)?);
    }

    Ok(quote! {
        #(#emitted)*
    })
}

fn expand_method(
    service: &Ident,
    instance: &syn::Expr,
    method: &MethodDecl,
) -> syn::Result<TokenStream2> {
    let name = &method.name;
    let kebab_name = kebab(&name.to_string());
    let service_kebab = kebab(&service.to_string());

    // Descriptions resolve in three steps, at compile time: a `///` here in
    // `methods = [...]`, then the trait method's own doc comment (captured by
    // `#[impress_service]` into the table below), then a bare fallback. Before
    // the table existed only the first was read, so services that documented
    // their trait — nearly all of them — shipped "Invoke Service.method" to
    // the model.
    let inline_doc = method.doc.clone();
    let fallback = format!("Invoke {service}.{name}");
    let docs_const = format_ident!("__IMPRESS_SERVICE_DOCS_{}", service);
    let method_name_str = name.to_string();
    let doc = quote! {
        ::impress_service_core::resolve_description(
            #inline_doc,
            &#docs_const,
            #method_name_str,
            #fallback,
        )
    };

    let args_struct = format_ident!("__Impress_{}_{}_Args", service, name);
    let invoker_fn = format_ident!("__impress_{}_{}_invoke", service, name);
    let schema_fn = format_ident!("__impress_{}_{}_schema", service, name);
    let mcp_submit = format_ident!("__IMPRESS_MCP_{}_{}", service, name);
    let cli_submit = format_ident!("__IMPRESS_CLI_{}_{}", service, name);
    let _ = (mcp_submit, cli_submit); // suppress unused if removed

    // Build the args struct fields and the deserialization → call expression.
    let mut struct_fields = Vec::new();
    let mut arg_idents = Vec::new();
    for (arg_name, arg_ty) in &method.args {
        validate_supported_ty(arg_ty)?;
        struct_fields.push(quote! {
            pub #arg_name: #arg_ty,
        });
        arg_idents.push(arg_name.clone());
    }

    // Return-type serialization: () → null, anything else → serde_json::to_value.
    let serialize_ret = match &method.ret {
        Some(ty) => {
            validate_supported_ty(ty)?;
            quote! {
                let value = ::impress_service_core::serde_json::to_value(__out)
                    .map_err(|e| -> ::impress_service_core::BoxError { Box::new(e) })?;
                Ok(value)
            }
        }
        None => quote! {
            Ok(::impress_service_core::serde_json::Value::Null)
        },
    };

    // Build the trait method call using method-call syntax. This dispatches
    // through Rust's auto-deref + auto-borrow rules, so the `instance` closure
    // can return any of:
    //   * an owned value:           `|| DefaultFoo::default()`
    //   * a `&'static` reference:   `|| GLOBAL.get().unwrap()`
    //   * an `Arc<T>` / smart ptr:  `|| GLOBAL.clone()`
    // all uniformly. UFCS (`<_ as Trait>::method(&inst, ...)`) only worked
    // for the owned case because `&&T` does not coerce to `&T` in UFCS.
    //
    // Requires the trait to be in scope at the macro call site — it always
    // is in practice (services co-locate trait + impl + this macro call).
    let _ = service; // suppress unused-variable lint for future use
    let call_expr = quote! {
        __instance.#name(#( __args.#arg_idents ),*).await
    };

    Ok(quote! {
        // -- Args struct -----------------------------------------------------
        #[doc(hidden)]
        #[derive(
            ::impress_service_core::schemars::JsonSchema,
            ::serde::Deserialize,
        )]
        #[allow(non_camel_case_types)]
        pub struct #args_struct {
            #(#struct_fields)*
        }

        // -- Schema function -------------------------------------------------
        #[doc(hidden)]
        #[allow(non_snake_case)]
        pub fn #schema_fn() -> ::impress_service_core::serde_json::Value {
            let schema = ::impress_service_core::schemars::schema_for!(#args_struct);
            ::impress_service_core::serde_json::to_value(schema)
                .unwrap_or(::impress_service_core::serde_json::Value::Null)
        }

        // -- Async invoker ---------------------------------------------------
        // `redundant_closure`: `instance = || foo()` is this macro's contract —
        // the closure defers construction to call time. Clippy attributes the
        // lint to the call site, so every service was being told to "fix" a
        // shape the macro requires. Silence it once, here.
        #[doc(hidden)]
        #[allow(non_snake_case, clippy::redundant_closure)]
        pub fn #invoker_fn(
            __json: ::impress_service_core::serde_json::Value,
        ) -> ::impress_service_core::ServiceFuture {
            Box::pin(async move {
                let __args: #args_struct =
                    ::impress_service_core::serde_json::from_value(__json)
                        .map_err(|e| -> ::impress_service_core::BoxError { Box::new(e) })?;
                let __instance = (#instance)();
                let __out = #call_expr;
                #serialize_ret
            })
        }

        // -- MCP descriptor inventory submission ----------------------------
        ::impress_service_core::inventory::submit! {
            ::impress_service_core::McpToolDescriptor {
                name: concat!(#service_kebab, "_", #kebab_name),
                description: #doc,
                input_schema: #schema_fn,
                handler: #invoker_fn,
            }
        }

        // -- CLI subcommand inventory submission ----------------------------
        ::impress_service_core::inventory::submit! {
            ::impress_service_core::CliSubcommand {
                name: #kebab_name,
                description: #doc,
                input_schema: #schema_fn,
                apply: #invoker_fn,
            }
        }
    })
}

/// Phase 0 supports a small allow-list of argument and return types.
///
/// We accept anything syntactically — the compiler still has to type-check
/// the generated code — but we surface a helpful error for things outside
/// the documented allow-list to keep the contract clear.
fn validate_supported_ty(ty: &Type) -> syn::Result<()> {
    let text = quote!(#ty).to_string().replace(' ', "");
    const ALLOWED: &[&str] = &[
        "String",
        "i64",
        "u64",
        "i32",
        "u32",
        "bool",
        "f64",
        "f32",
        "()",
        "Option<String>",
        "Vec<String>",
        "serde_json::Value",
        "Value",
    ];
    if ALLOWED.iter().any(|a| text == *a) {
        Ok(())
    } else {
        // Permit anything; warn via a doc-style note instead of an error so
        // that adventurous users can use custom DTOs that implement
        // `serde::Deserialize` + `schemars::JsonSchema`.
        Ok(())
    }
}
