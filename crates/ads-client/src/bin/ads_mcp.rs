//! MCP server binary for the ADS client.
//!
//! Reads JSON-RPC 2.0 from stdin, writes responses to stdout.
//! Usage: ads-mcp (requires ADS_API_TOKEN env var)

#[cfg(feature = "mcp")]
#[tokio::main]
async fn main() {
    let client = match ads_client::AdsClient::from_env() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: {}", e);
            eprintln!("Set ADS_API_TOKEN environment variable to your ADS API key.");
            eprintln!("Get one at: https://ui.adsabs.harvard.edu/user/settings/token");
            std::process::exit(1);
        }
    };

    if let Err(e) = ads_client::mcp::run_server(client).await {
        eprintln!("MCP server error: {}", e);
        std::process::exit(1);
    }
}

#[cfg(not(feature = "mcp"))]
fn main() {
    eprintln!("This binary requires the 'mcp' feature. Build with: cargo build --features mcp");
    std::process::exit(1);
}
