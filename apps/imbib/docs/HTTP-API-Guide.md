# imbib HTTP API: Integration Guide for AI Tools and External Programs

imbib provides a local HTTP API that enables seamless integration with AI writing assistants, code editors, command-line tools, and browser extensions. This guide explains how any external program can safely interface with your imbib library.

## Overview

The imbib HTTP server runs locally on your machine at `http://127.0.0.1:23120`. This design provides several important benefits:

- **Privacy**: Your library data never leaves your machine
- **Security**: Only local programs can access the API (no internet exposure)
- **Speed**: Direct local access with no network latency
- **Offline**: Works without an internet connection
- **Universal**: Any program that can make HTTP requests can integrate

## Enabling the HTTP Server

1. Open imbib
2. Go to **Settings > General**
3. In the **Automation** section, enable "Enable automation API"
4. In the **HTTP Server** section, enable "Enable HTTP server"
5. (Optional) Change the port if 23120 conflicts with another service

The server starts automatically when imbib launches if enabled.

---

## API Reference

All endpoints return JSON responses with this structure:

```json
{
  "status": "ok",
  "...": "endpoint-specific data"
}
```

On error:
```json
{
  "status": "error",
  "error": "Description of what went wrong"
}
```

### Check Server Status

```
GET /api/status
```

Returns server health and library statistics.

**Response:**
```json
{
  "status": "ok",
  "version": "1.0.0",
  "libraryCount": 1234,
  "collectionCount": 12,
  "serverPort": 23120
}
```

**Use case:** Check if imbib is running before attempting other operations.

---

### Search Library

```
GET /api/search?q={query}&limit={n}&offset={n}
```

Search your library by title, author, abstract, or cite key.

**Parameters:**
| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `q` | No | "" | Search query (empty returns all papers) |
| `limit` | No | 50 | Maximum results to return |
| `offset` | No | 0 | Skip first N results (for pagination) |

**Response:**
```json
{
  "status": "ok",
  "query": "dark matter",
  "count": 15,
  "limit": 50,
  "offset": 0,
  "papers": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "citeKey": "Navarro1996NFW",
      "title": "The Structure of Cold Dark Matter Halos",
      "authors": ["Navarro, Julio F.", "Frenk, Carlos S.", "White, Simon D. M."],
      "year": 1996,
      "venue": "The Astrophysical Journal",
      "doi": "10.1086/177173",
      "arxivID": "astro-ph/9508025",
      "bibcode": "1996ApJ...462..563N",
      "isRead": true,
      "isStarred": false,
      "hasPDF": true,
      "bibtex": "@article{Navarro1996NFW, ...}",
      "dateAdded": "2024-03-15T10:30:00Z",
      "dateModified": "2024-03-15T10:30:00Z"
    }
  ]
}
```

---

### Get Single Paper

```
GET /api/papers/{citeKey}
```

Retrieve a specific paper by its cite key.

**Response:**
```json
{
  "status": "ok",
  "paper": {
    "citeKey": "Einstein1905SR",
    "title": "On the Electrodynamics of Moving Bodies",
    "authors": ["Einstein, Albert"],
    "year": 1905,
    "bibtex": "@article{Einstein1905SR, ...}",
    ...
  }
}
```

**Error (404):**
```json
{
  "status": "error",
  "error": "Paper not found: InvalidKey"
}
```

---

### Export BibTeX

```
GET /api/export?keys={key1,key2,...}&format={bibtex|ris}
```

Export bibliography entries for specified cite keys.

**Parameters:**
| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `keys` | Yes | - | Comma-separated cite keys |
| `format` | No | bibtex | Export format: `bibtex` or `ris` |

**Response:**
```json
{
  "status": "ok",
  "format": "bibtex",
  "paperCount": 2,
  "content": "@article{Einstein1905SR,\n  author = {Einstein, Albert},\n  ...\n}\n\n@article{Hawking1974BH, ...}"
}
```

---

### List Collections

```
GET /api/collections
```

List all collections in your library.

**Response:**
```json
{
  "status": "ok",
  "count": 5,
  "collections": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "name": "Cosmology",
      "paperCount": 47,
      "isSmartCollection": false,
      "libraryID": "...",
      "libraryName": "Main Library"
    }
  ]
}
```

---

## Integration Examples

### Example 1: OpenAI Prism (LaTeX Editor)

OpenAI's Prism is a cloud-based LaTeX workspace for scientists. While Prism runs in your browser, you can use imbib's HTTP API through:

**Option A: Browser Extension (Recommended)**
The imbib Safari extension includes a citation picker that communicates with the HTTP server:

1. Enable the HTTP server in imbib settings
2. Install the imbib Safari extension
3. In Prism, click the imbib toolbar icon
4. Switch to the "Search" tab
5. Search your library and click to copy `\cite{key}` or full BibTeX

**Option B: Manual Workflow**
```bash
# Search for papers about "cosmological simulations"
curl "http://127.0.0.1:23120/api/search?q=cosmological+simulations&limit=10"

# Get BibTeX for specific papers
curl "http://127.0.0.1:23120/api/export?keys=Springel2005,Boylan2009"
```

Copy the BibTeX into your Prism project's bibliography file.

---

### Example 2: Claude Desktop / Claude Code

Claude can use imbib as a tool for finding and citing papers. Add imbib to your MCP configuration:

```json
{
  "mcpServers": {
    "imbib": {
      "command": "curl",
      "args": ["http://127.0.0.1:23120/api/search?q=${query}"]
    }
  }
}
```

Or use URL schemes directly:
```
imbib://search?q=neural+networks&return=pasteboard
```

---

### Example 3: VS Code / Cursor

Create a custom task or extension that queries imbib:

```javascript
// Example: VS Code extension snippet
async function searchImbib(query) {
  const response = await fetch(
    `http://127.0.0.1:23120/api/search?q=${encodeURIComponent(query)}`
  );
  const data = await response.json();
  return data.papers;
}

async function insertCitation() {
  const query = await vscode.window.showInputBox({ prompt: "Search imbib" });
  const papers = await searchImbib(query);

  // Show quick pick to select paper
  const selected = await vscode.window.showQuickPick(
    papers.map(p => ({ label: p.title, detail: p.citeKey, paper: p }))
  );

  // Insert \cite{key} at cursor
  const editor = vscode.window.activeTextEditor;
  editor.edit(edit => {
    edit.insert(editor.selection.active, `\\cite{${selected.paper.citeKey}}`);
  });
}
```

---

### Example 4: Command-Line Tool

Create a simple shell function for quick lookups:

```bash
# Add to ~/.zshrc or ~/.bashrc
imbib-search() {
  curl -s "http://127.0.0.1:23120/api/search?q=$1&limit=10" | jq '.papers[] | "\(.citeKey): \(.title)"'
}

imbib-bibtex() {
  curl -s "http://127.0.0.1:23120/api/export?keys=$1" | jq -r '.content'
}

# Usage:
# $ imbib-search "dark energy"
# $ imbib-bibtex "Riess1998,Perlmutter1999"
```

---

### Example 5: Python Script

```python
import requests

IMBIB_API = "http://127.0.0.1:23120"

def search_library(query: str, limit: int = 20) -> list:
    """Search imbib library for papers matching query."""
    response = requests.get(
        f"{IMBIB_API}/api/search",
        params={"q": query, "limit": limit}
    )
    response.raise_for_status()
    return response.json()["papers"]

def get_bibtex(cite_keys: list[str]) -> str:
    """Export BibTeX for given cite keys."""
    response = requests.get(
        f"{IMBIB_API}/api/export",
        params={"keys": ",".join(cite_keys)}
    )
    response.raise_for_status()
    return response.json()["content"]

def is_imbib_running() -> bool:
    """Check if imbib HTTP server is available."""
    try:
        response = requests.get(f"{IMBIB_API}/api/status", timeout=1)
        return response.json().get("status") == "ok"
    except:
        return False

# Example usage
if is_imbib_running():
    papers = search_library("machine learning")
    for paper in papers[:5]:
        print(f"{paper['citeKey']}: {paper['title']}")

    # Get BibTeX for top results
    keys = [p["citeKey"] for p in papers[:3]]
    bibtex = get_bibtex(keys)
    print(bibtex)
```

---

### Example 6: Raycast / Alfred Extension

For macOS power users, create a Raycast script command:

```bash
#!/bin/bash
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Search imbib
# @raycast.mode fullOutput
# @raycast.argument1 { "type": "text", "placeholder": "Search query" }

curl -s "http://127.0.0.1:23120/api/search?q=$1&limit=5" | \
  jq -r '.papers[] | "[\(.citeKey)] \(.title) (\(.year // "n/d"))"'
```

---

## Building Custom Integrations

### General Pattern

Any integration follows this pattern:

1. **Check availability**: `GET /api/status`
2. **Search**: `GET /api/search?q=...`
3. **Retrieve**: `GET /api/papers/{key}` or `GET /api/export?keys=...`
4. **Use**: Insert citation, copy BibTeX, etc.

### Error Handling

Always handle these cases:

```javascript
async function safeImbibRequest(endpoint) {
  try {
    const response = await fetch(`http://127.0.0.1:23120${endpoint}`);

    if (!response.ok) {
      if (response.status === 403) {
        throw new Error("imbib automation API is disabled. Enable it in Settings.");
      }
      throw new Error(`HTTP ${response.status}`);
    }

    const data = await response.json();
    if (data.status === "error") {
      throw new Error(data.error);
    }

    return data;
  } catch (error) {
    if (error.name === "TypeError") {
      throw new Error("imbib is not running or HTTP server is disabled.");
    }
    throw error;
  }
}
```

### CORS Note

The server includes permissive CORS headers, so browser-based tools can make requests directly:

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, POST, OPTIONS
Access-Control-Allow-Headers: Content-Type, Authorization
```

---

## Security Considerations

The HTTP API is designed with security in mind:

| Feature | Protection |
|---------|------------|
| Localhost binding | Only `127.0.0.1` - cannot be accessed from network |
| Opt-in | Disabled by default, user must explicitly enable |
| Read-only | No write operations - cannot modify your library |
| No authentication bypass | Requires automation API to be enabled |

**Best Practices:**
- Only enable the HTTP server when you need it
- The server automatically stops when imbib quits
- Review enabled integrations periodically

---

## Comparison with Other Reference Managers

| Feature | imbib | Zotero | Mendeley |
|---------|-------|--------|----------|
| Local HTTP API | Port 23120 | Port 23119 | None |
| Localhost only | Yes | Yes | N/A |
| Read-only safe | Yes | Mixed | N/A |
| BibTeX native | Yes | Via plugin | Export only |
| Browser extension | Safari | All browsers | Chrome/Firefox |

imbib's API is intentionally similar to Zotero's for familiarity, but with a cleaner JSON interface and BibTeX-first design.

---

## Troubleshooting

### Server not responding

1. Ensure imbib is running
2. Check Settings > General > HTTP Server is enabled
3. Verify the port (default 23120) isn't blocked
4. Try: `curl http://127.0.0.1:23120/api/status`

### "Automation API disabled" error

Enable "Enable automation API" in Settings > General > Automation.

### Port conflict

Change the port in Settings > General > HTTP Server if another application uses 23120.

### Browser extension can't connect

1. Ensure HTTP server is enabled in imbib
2. Check browser extension permissions for localhost access
3. Verify no firewall is blocking local connections

---

## Future Enhancements

The HTTP API may expand to include:

- `POST /api/papers` - Add papers from external sources
- `PUT /api/papers/{key}` - Update paper metadata
- `WebSocket` support for real-time updates
- Authentication tokens for multi-user scenarios

These would remain opt-in with the same security model.

---

## Summary

imbib's HTTP API enables any tool that can make HTTP requests to search your library and retrieve citations. Whether you're using AI writing assistants like Prism, code editors like VS Code, or building custom scripts, the pattern is simple:

1. Enable the HTTP server in imbib
2. Make requests to `http://127.0.0.1:23120/api/...`
3. Parse the JSON response
4. Use the citations in your workflow

Your library stays private, the API is read-only, and integration is straightforward.
