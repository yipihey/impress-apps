# MCP Integration Guide: AI Assistant Setup for imbib and imprint

Connect your AI tools—Claude Desktop, Claude Code, Cursor, Zed, and more—to your imbib paper library and imprint documents using the Model Context Protocol (MCP).

## What is MCP?

The **Model Context Protocol** (MCP) is an open standard that lets AI assistants interact with external tools and data sources. With the `impress-mcp` server, AI assistants can:

- Search your paper library and retrieve citations
- Read and edit your documents
- Insert citations from imbib into imprint documents
- Compile documents to PDF

All communication stays on your local machine—your data never leaves your computer.

## Quick Start

**Time required:** About 5 minutes

### Step 1: Enable HTTP APIs

Both imbib and imprint need their HTTP APIs enabled:

**In imbib:**
1. Open imbib
2. Go to **Settings → General**
3. In **Automation**, enable "Enable automation API"
4. In **HTTP Server**, enable "Enable HTTP server"

**In imprint:**
1. Open imprint
2. Go to **Settings → Automation**
3. Enable "Enable HTTP API"

### Step 2: Install the MCP Server

```bash
npm install -g impress-mcp
```

Or use directly with npx (no installation required):

```bash
npx impress-mcp
```

### Step 3: Configure Your AI Tool

Choose your AI tool below and add the configuration.

---

## Client Configurations

### Claude Desktop

**Location:** `~/Library/Application Support/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "impress": {
      "command": "npx",
      "args": ["impress-mcp"]
    }
  }
}
```

After editing, restart Claude Desktop.

### Claude Code (CLI)

Option 1 - Use the `claude mcp add` command:

```bash
claude mcp add impress npx impress-mcp
```

Option 2 - Add to your settings file at `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "impress": {
      "command": "npx",
      "args": ["impress-mcp"]
    }
  }
}
```

### Cursor

1. Open Settings (Cmd+,)
2. Search for "MCP"
3. Click "Add Server"
4. Configure:
   - **Name:** impress
   - **Command:** npx
   - **Args:** impress-mcp

### Zed

Add to your Zed settings:

```json
{
  "language_models": {
    "mcp_servers": {
      "impress": {
        "command": "npx",
        "args": ["impress-mcp"]
      }
    }
  }
}
```

### Other MCP-Compatible Tools

Any tool that supports MCP can use the same configuration pattern:

```json
{
  "command": "npx",
  "args": ["impress-mcp"]
}
```

### Custom Port Configuration

If you've changed the default ports, set environment variables:

```json
{
  "mcpServers": {
    "impress": {
      "command": "npx",
      "args": ["impress-mcp"],
      "env": {
        "IMBIB_PORT": "23120",
        "IMPRINT_PORT": "23121"
      }
    }
  }
}
```

---

## What You Can Do

### Library Tools (imbib)

| Tool | Description | Example Use |
|------|-------------|-------------|
| `imbib_search_library` | Search papers by title, author, keywords | "Find papers about attention mechanisms" |
| `imbib_get_paper` | Get full details for a specific paper | "Get the BibTeX for Vaswani2017" |
| `imbib_export_bibtex` | Export BibTeX for multiple papers | "Export citations for these 5 papers" |
| `imbib_list_collections` | Browse your paper organization | "What collections do I have?" |
| `imbib_status` | Check connection to imbib | "Is imbib running?" |

### Document Tools (imprint)

| Tool | Description | Example Use |
|------|-------------|-------------|
| `imprint_list_documents` | See all open documents | "What documents are open?" |
| `imprint_get_document` | Get document metadata | "Show me the thesis document" |
| `imprint_get_content` | Read document source | "Read my paper draft" |
| `imprint_create_document` | Create a new document | "Start a new paper" |
| `imprint_insert_citation` | Add a citation | "Cite Vaswani2017 here" |
| `imprint_compile` | Compile to PDF | "Compile my document" |
| `imprint_update_document` | Edit document content | "Update the abstract" |
| `imprint_status` | Check connection to imprint | "Is imprint running?" |

### Example Workflows

**Research a topic and cite papers:**
```
You: "Find papers about transformer architectures and add the top 3 to my literature review"

AI: [Searches library] → [Gets BibTeX] → [Inserts citations into document]
```

**Quick citation lookup:**
```
You: "What's the cite key for the original attention paper?"

AI: [Searches for "attention is all you need"] → "It's Vaswani2017Attention"
```

**Compile and review:**
```
You: "Compile my paper and tell me if there are any undefined citations"

AI: [Compiles document] → [Reports any issues]
```

---

## Verification

### Using the Check Command

Run the diagnostic command to verify everything is set up correctly:

```bash
npx impress-mcp --check
```

**Successful output:**
```
impress-mcp connection check

✓ imbib HTTP API responding on port 23120
  → Library: 1,234 papers
  → Collections: 12

✓ imprint HTTP API responding on port 23121
  → Open documents: 2

Ready! Add this to your AI tool:

{
  "mcpServers": {
    "impress": {
      "command": "npx",
      "args": ["impress-mcp"]
    }
  }
}
```

### Manual Testing

Test the APIs directly with curl:

```bash
# Test imbib
curl http://127.0.0.1:23120/api/status

# Test imprint
curl http://127.0.0.1:23121/api/status
```

---

## Security

The impress-mcp server is designed with security as a priority:

| Feature | Protection |
|---------|------------|
| **Localhost only** | APIs bind to `127.0.0.1`—cannot be accessed from network |
| **Explicit opt-in** | HTTP APIs are disabled by default; you must enable them |
| **No external network** | All communication stays on your machine |
| **Read-focused** | Most operations are read-only; writes require explicit user action |
| **No credentials** | No passwords or tokens stored; uses local process trust |

### Best Practices

- Only enable the HTTP APIs when you need AI integration
- The servers stop when you quit the apps
- Review what data AI tools access via the MCP protocol

---

## Troubleshooting

### Connection Issues

| Problem | Solution |
|---------|----------|
| "imbib is not running" | Open the imbib app |
| "imprint is not running" | Open the imprint app |
| "HTTP API is disabled" | Enable in Settings → Automation |
| "Connection refused" | Check firewall isn't blocking localhost |
| Port conflict | Change port in app settings |

### MCP Server Issues

| Problem | Solution |
|---------|----------|
| "command not found: npx" | Install Node.js from nodejs.org |
| "Cannot find module 'impress-mcp'" | Run `npm install -g impress-mcp` |
| Server starts but tools don't work | Run `npx impress-mcp --check` to diagnose |

### AI Tool Issues

| Problem | Solution |
|---------|----------|
| Claude Desktop doesn't show tools | Restart Claude Desktop after config change |
| "Server not responding" | Check both apps are running with APIs enabled |
| Tools time out | Increase timeout in AI tool settings if available |

### Getting Help

1. Run `npx impress-mcp --check` for diagnostics
2. Check the app console windows for error messages
3. Verify settings in both imbib and imprint

---

## Comparison with Direct HTTP API

You can also use the HTTP APIs directly without MCP:

| Approach | Best For |
|----------|----------|
| **MCP (impress-mcp)** | AI assistants (Claude, Cursor, etc.) |
| **HTTP API** | Scripts, browser extensions, custom tools |
| **URL Schemes** | Shortcuts app, Alfred, Raycast |

For direct HTTP API usage, see the [HTTP API Guide](HTTP-API-Guide.md).

---

## Summary

1. **Enable** HTTP APIs in imbib and imprint settings
2. **Configure** your AI tool with the impress-mcp server
3. **Verify** with `npx impress-mcp --check`
4. **Use** natural language to search your library and manage documents

Your library stays private, all communication is local, and integration is opt-in.
