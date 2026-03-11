mod discover;
mod execute;
mod server;
mod types;

use tracing_subscriber::EnvFilter;

const DEFAULT_PORT: u16 = 23119;
const DEFAULT_BIND: &str = "127.0.0.1";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize tracing
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("impress_toolbox=info,tower_http=info")),
        )
        .init();

    // Parse CLI args (minimal, no clap dependency)
    let args: Vec<String> = std::env::args().collect();
    let port = parse_arg(&args, "--port")
        .and_then(|s| s.parse::<u16>().ok())
        .unwrap_or(DEFAULT_PORT);
    let bind = parse_arg(&args, "--bind").unwrap_or_else(|| DEFAULT_BIND.to_string());

    let addr = format!("{}:{}", bind, port);

    tracing::info!(
        version = env!("CARGO_PKG_VERSION"),
        pid = std::process::id(),
        "Starting impress-toolbox"
    );

    server::serve(&addr).await
}

/// Simple CLI arg parser: --key value
fn parse_arg(args: &[String], key: &str) -> Option<String> {
    args.windows(2)
        .find(|w| w[0] == key)
        .map(|w| w[1].clone())
}
