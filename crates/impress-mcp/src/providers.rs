//! Runtime provider startup is a host concern. The pure registry never opens
//! the user's store just because a caller enumerates linked descriptors.
use std::io::Read;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::sync::Arc;

pub fn restore() -> Result<(), Box<dyn std::error::Error>> {
    if impress_store_service::providers::install_if_registered(Arc::new(
        impress_app_transport::provider::JsonSchemaValidator,
    ))? {
        impress_service_core::runtime::block_on(
            impress_service_core::registry_runtime::refresh_health(),
        );
    }
    Ok(())
}

fn read_host_token(token_file: &Path) -> Result<String, Box<dyn std::error::Error>> {
    let metadata = std::fs::symlink_metadata(token_file)?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o077 != 0 || metadata.len() > 4096 {
        return Err(
            "the host token file must be a private regular file of at most 4096 bytes".into(),
        );
    }
    let file = std::fs::File::open(token_file)?;
    let opened = file.metadata()?;
    if !opened.is_file()
        || opened.permissions().mode() & 0o077 != 0
        || opened.dev() != metadata.dev()
        || opened.ino() != metadata.ino()
    {
        return Err("the host token file changed while opening it".into());
    }
    let mut token = String::new();
    file.take(4097).read_to_string(&mut token)?;
    if token.len() > 4096 {
        return Err("the host token file exceeds 4096 bytes".into());
    }
    let token = token.trim();
    if token.len() < 32 {
        return Err("the host token must contain at least 32 characters".into());
    }
    Ok(token.to_owned())
}

pub fn run_http(bind: &str, token_file: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let address: std::net::SocketAddr = bind.parse()?;
    if !address.ip().is_loopback() {
        return Err("the suite MCP provider host must bind a loopback address".into());
    }
    let token = read_host_token(token_file)?;
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
    impress_mcp_host::run_http(config, bind, token)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_credentials_require_a_bounded_private_regular_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("host-token");
        let token = "a".repeat(64);
        std::fs::write(&path, &token).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(read_host_token(&path).unwrap(), token);
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(read_host_token(&link).is_err());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_host_token(&path).is_err());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::write(&path, "a".repeat(4097)).unwrap();
        assert!(read_host_token(&path).is_err());
        std::fs::write(&path, "short").unwrap();
        assert!(read_host_token(&path).is_err());
    }
}
