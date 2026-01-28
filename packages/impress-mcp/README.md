# impress-mcp

MCP (Model Context Protocol) server for the impress suite, enabling AI agents to interact with your academic research workflow.

## Features

### imbib Integration
- **Search library** - Find papers by title, author, keywords
- **Get paper details** - Full metadata, abstract, and BibTeX
- **Export BibTeX** - Generate citations for multiple papers
- **List collections** - Browse your paper organization

### imprint Integration
- **List documents** - See all open documents
- **Get document content** - Read Typst source
- **Insert citations** - Add references from imbib
- **Compile to PDF** - Trigger document compilation
- **Update content** - Modify document source

## Quick Start

### 1. Enable HTTP APIs

**In imbib:** Settings → General → Automation → Enable HTTP Server

**In imprint:** Settings → Automation → Enable HTTP API

### 2. Test the Connection

```bash
npx impress-mcp --check
```

This will verify both apps are running and show you the configuration to use.

### 3. Configure Your AI Tool

Copy the configuration from the check output and add it to your AI tool.

## Installation

```bash
npm install -g impress-mcp
```

Or run directly with npx (recommended):

```bash
npx impress-mcp
```

## Command Line Usage

```bash
npx impress-mcp          # Run the MCP server (stdio transport)
npx impress-mcp --check  # Test connections and show configuration
npx impress-mcp --help   # Show help message
```

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

### Claude Code (CLI)

```bash
claude mcp add impress npx impress-mcp
```

Or add to `~/.claude/settings.json`:

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

Settings → MCP → Add Server:
- Name: `impress`
- Command: `npx`
- Args: `impress-mcp`

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

### Environment Variables

- `IMBIB_PORT` - imbib HTTP API port (default: 23120)
- `IMPRINT_PORT` - imprint HTTP API port (default: 23121)

## Prerequisites

1. **imbib** - Enable HTTP Server in Settings → General → Automation
2. **imprint** - Enable HTTP API in Settings → Automation

Both apps must be running for full functionality. The MCP server will connect to whichever apps are available.

## Tools

### imbib Tools

| Tool | Description |
|------|-------------|
| `imbib_search_library` | Search papers by query |
| `imbib_get_paper` | Get paper by cite key |
| `imbib_export_bibtex` | Export BibTeX entries |
| `imbib_list_collections` | List all collections |
| `imbib_status` | Check imbib status |

### imprint Tools

| Tool | Description |
|------|-------------|
| `imprint_list_documents` | List open documents |
| `imprint_get_document` | Get document metadata |
| `imprint_get_content` | Get document source |
| `imprint_create_document` | Create new document |
| `imprint_insert_citation` | Insert citation |
| `imprint_compile` | Compile to PDF |
| `imprint_update_document` | Update content |
| `imprint_status` | Check imprint status |

## Resources

The server also exposes MCP resources:

- `impress://imbib/library` - Paper library summary
- `impress://imbib/collections` - Collection list
- `impress://imprint/documents` - Open documents
- `impress://imprint/documents/{id}` - Document content

## Example Usage

### Search and cite a paper

```
User: Find papers about attention mechanisms and cite Vaswani2017 in my document

AI: Let me search your library and insert the citation.

[Calls imbib_search_library with query "attention mechanism"]
[Calls imbib_get_paper with citeKey "Vaswani2017Attention"]
[Calls imprint_list_documents to find the active document]
[Calls imprint_insert_citation with the cite key and BibTeX]

I've inserted @Vaswani2017Attention into your document along with the BibTeX entry.
```

### Get library overview

```
User: What papers do I have about transformers?

AI: [Calls imbib_search_library with query "transformers"]

You have 15 papers about transformers in your library:
- Vaswani2017Attention: Attention Is All You Need (2017)
- Devlin2018BERT: BERT: Pre-training of Deep Bidirectional... (2018)
...
```

## Development

```bash
# Install dependencies
npm install

# Build
npm run build

# Run in development
npm run dev

# Run tests
npm test
```

## Security

- Both imbib and imprint HTTP APIs are localhost-only (127.0.0.1)
- No network exposure - all communication stays on your machine
- APIs require explicit user opt-in in app settings

## Troubleshooting

### Quick Diagnosis

Run the check command to see what's working:

```bash
npx impress-mcp --check
```

### Common Issues

| Problem | Solution |
|---------|----------|
| "imbib is not running" | Open the imbib app |
| "imprint is not running" | Open the imprint app |
| "HTTP API is disabled" | Enable in app Settings → Automation |
| "command not found: npx" | Install Node.js from nodejs.org |
| Server starts but AI tool doesn't see it | Restart your AI tool after adding config |
| Port conflict | Change port in app settings, set `IMBIB_PORT`/`IMPRINT_PORT` env vars |

### Testing APIs Manually

```bash
# Test imbib
curl http://127.0.0.1:23120/api/status

# Test imprint
curl http://127.0.0.1:23121/api/status
```

### Getting Help

1. Run `npx impress-mcp --check` for diagnostics
2. Check the console output in your AI tool
3. Verify HTTP APIs are enabled in both apps
4. See the [full setup guide](https://imbib.com/docs/MCP-Setup-Guide)

## License

MIT
