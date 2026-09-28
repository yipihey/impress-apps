//! Runtime provider startup is a host concern. The pure registry never opens
//! the user's store just because a caller enumerates linked descriptors.
use std::path::Path;
use std::sync::Arc;
use std::os::unix::fs::PermissionsExt;

pub fn restore() -> Result<(), Box<dyn std::error::Error>> {
    if impress_store_service::providers::install_if_registered(Arc::new(
        impress_app_transport::provider::JsonSchemaValidator,
    ))? {
        impress_service_core::runtime::block_on(impress_service_core::registry_runtime::refresh_health());
    }
    Ok(())
}

pub fn run_http(bind: &str, token_file: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let address: std::net::SocketAddr = bind.parse()?;
    if !address.ip().is_loopback() {
        return Err("the suite MCP provider host must bind a loopback address".into());
    }
    let metadata = std::fs::symlink_metadata(token_file)?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o077 != 0 || metadata.len() > 4096 {
        return Err("the host token file must be a private regular file of at most 4096 bytes".into());
    }
    let token = std::fs::read_to_string(token_file)?;
    let token = token.trim();
    if token.len() < 32 {
        return Err("the host token must contain at least 32 characters".into());
    }
    impress_capabilities::force_link();
    impress_store_service::providers::install_for_selected_store(Arc::new(
        impress_app_transport::provider::JsonSchemaValidator,
    ))?;
    let config = impress_mcp_host::HostConfig {
        server_name: "impress".into(),
        server_version: env!("CARGO_PKG_VERSION").into(),
        instructions: "The Impress research suite: one inventory of linked and registered provider verbs. Provider calls use the same policy and audit pipeline.".into(),
        allowed_tool_prefixes: vec![], resources: vec![], tool_ui: vec![], tool_file_params: vec![],
    };
    impress_mcp_host::run_http(config, bind, token.to_owned())
}
