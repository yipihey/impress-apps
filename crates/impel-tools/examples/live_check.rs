//! Live end-to-end check of the impel-tools surface against running siblings.

fn main() {
    let backends = impel_tools::configure(
        Some("http://127.0.0.1:23120".into()),
        Some("http://127.0.0.1:23121".into()),
    );
    println!("backends: imbib={:?} imprint={:?}", backends.imbib, backends.imprint);

    let all = impel_tools::list_tools();
    let available = impel_tools::list_available_tools();
    println!("tools: {} total, {} available", all.len(), available.len());

    // A read-only call with no arguments, to prove dispatch reaches the app.
    match impel_tools::call_tool("imbib-library-service_list-libraries".into(), "{}".into()) {
        Ok(v) => {
            let head: String = v.chars().take(180).collect();
            println!("list-libraries OK: {head}");
        }
        Err(e) => println!("list-libraries ERR: {e}"),
    }

    // A pure-compute tool that needs no app at all.
    match impel_tools::call_tool(
        "imbib-text-service_decode-latex".into(),
        r#"{"input":"Caf\\'{e}"}"#.into(),
    ) {
        Ok(v) => println!("decode-latex OK: {v}"),
        Err(e) => println!("decode-latex ERR: {e}"),
    }
}
