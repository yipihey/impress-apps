//! MCP server setup for AI editors
//!
//! Auto-detects installed editors (Claude Code, Claude Desktop, Cursor, Zed)
//! and writes MCP server configuration so they can use im-identifiers tools.

use std::fs;
use std::path::PathBuf;

/// Supported editor targets
#[derive(Debug, Clone, clap::ValueEnum)]
pub enum EditorTarget {
    /// Claude Code CLI
    ClaudeCode,
    /// Claude Desktop app
    ClaudeDesktop,
    /// Cursor editor
    Cursor,
    /// Zed editor
    Zed,
}

impl std::fmt::Display for EditorTarget {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ClaudeCode => write!(f, "Claude Code"),
            Self::ClaudeDesktop => write!(f, "Claude Desktop"),
            Self::Cursor => write!(f, "Cursor"),
            Self::Zed => write!(f, "Zed"),
        }
    }
}

struct EditorInfo {
    target: EditorTarget,
    config_path: PathBuf,
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn detect_editors(filter: Option<&EditorTarget>) -> Vec<EditorInfo> {
    let mut editors = Vec::new();
    let Some(home) = home_dir() else {
        return editors;
    };

    let candidates = [
        (
            EditorTarget::ClaudeCode,
            home.join(".claude/settings.json"),
            home.join(".claude"),
        ),
        (
            EditorTarget::ClaudeDesktop,
            home.join("Library/Application Support/Claude/claude_desktop_config.json"),
            home.join("Library/Application Support/Claude"),
        ),
        (
            EditorTarget::Cursor,
            home.join(".cursor/mcp.json"),
            home.join(".cursor"),
        ),
        (
            EditorTarget::Zed,
            home.join(".config/zed/settings.json"),
            home.join(".config/zed"),
        ),
    ];

    for (target, config_path, detect_dir) in candidates {
        if let Some(f) = filter {
            if std::mem::discriminant(f) != std::mem::discriminant(&target) {
                continue;
            }
        }
        if detect_dir.exists() || config_path.exists() {
            editors.push(EditorInfo {
                target,
                config_path,
            });
        }
    }

    editors
}

fn find_binary() -> Result<String, Box<dyn std::error::Error>> {
    let exe = std::env::current_exe()?;
    Ok(exe.to_string_lossy().to_string())
}

const SERVER_NAME: &str = "im-identifiers";

fn write_standard_config(
    editor: &EditorInfo,
    binary: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut config: serde_json::Value = if editor.config_path.exists() {
        let content = fs::read_to_string(&editor.config_path)?;
        serde_json::from_str(&content).unwrap_or_else(|_| serde_json::json!({}))
    } else {
        serde_json::json!({})
    };

    let servers = config
        .as_object_mut()
        .ok_or("Config is not a JSON object")?
        .entry("mcpServers")
        .or_insert_with(|| serde_json::json!({}));

    servers[SERVER_NAME] = serde_json::json!({
        "command": binary,
        "args": ["serve"]
    });

    if let Some(parent) = editor.config_path.parent() {
        fs::create_dir_all(parent)?;
    }

    fs::write(
        &editor.config_path,
        serde_json::to_string_pretty(&config)?,
    )?;

    Ok(())
}

fn write_zed_config(
    editor: &EditorInfo,
    binary: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut config: serde_json::Value = if editor.config_path.exists() {
        let content = fs::read_to_string(&editor.config_path)?;
        serde_json::from_str(&content).unwrap_or_else(|_| serde_json::json!({}))
    } else {
        serde_json::json!({})
    };

    let servers = config
        .as_object_mut()
        .ok_or("Config is not a JSON object")?
        .entry("context_servers")
        .or_insert_with(|| serde_json::json!({}));

    servers[SERVER_NAME] = serde_json::json!({
        "command": {
            "path": binary,
            "args": ["serve"]
        }
    });

    if let Some(parent) = editor.config_path.parent() {
        fs::create_dir_all(parent)?;
    }

    fs::write(
        &editor.config_path,
        serde_json::to_string_pretty(&config)?,
    )?;

    Ok(())
}

/// Run the setup wizard to configure MCP server for detected editors.
pub fn run_setup(editor: Option<EditorTarget>) -> Result<(), Box<dyn std::error::Error>> {
    let binary = find_binary()?;
    eprintln!("Binary: {binary}");

    let editors = detect_editors(editor.as_ref());

    if editors.is_empty() {
        if let Some(target) = &editor {
            eprintln!("Editor not detected: {target}");
        } else {
            eprintln!("No supported editors detected.");
            eprintln!("Supported: Claude Code, Claude Desktop, Cursor, Zed");
        }
        eprintln!("\nManual configuration:");
        eprintln!("  Add to your editor's MCP config:");
        eprintln!(
            "  {{\n    \"mcpServers\": {{\n      \"{SERVER_NAME}\": {{\n        \"command\": \"{binary}\",\n        \"args\": [\"serve\"]\n      }}\n    }}\n  }}"
        );
        return Ok(());
    }

    for editor_info in &editors {
        eprint!("Configuring {}... ", editor_info.target);
        let result = match editor_info.target {
            EditorTarget::Zed => write_zed_config(editor_info, &binary),
            _ => write_standard_config(editor_info, &binary),
        };
        match result {
            Ok(()) => {
                eprintln!("OK ({})", editor_info.config_path.display());
            }
            Err(e) => {
                eprintln!("FAILED: {e}");
            }
        }
    }

    eprintln!("\nDone. Restart your editor to activate the {} MCP server.", SERVER_NAME);
    Ok(())
}
