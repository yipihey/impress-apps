#!/usr/bin/env node
/**
 * impress-mcp - MCP Server for impress suite
 *
 * Provides AI agents access to:
 * - imbib: Academic paper library management
 * - imprint: Collaborative document editing
 *
 * Usage:
 *   npx impress-mcp          # Run with stdio transport
 *   npx impress-mcp --sse    # Run with SSE transport (port 3001)
 *   npx impress-mcp --check  # Test connections and show config
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ListResourcesRequestSchema,
  ReadResourceRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import { ImbibClient } from "./imbib/client.js";
import { ImbibTools, IMBIB_TOOLS } from "./imbib/tools.js";
import { ImprintClient } from "./imprint/client.js";
import { ImprintTools, IMPRINT_TOOLS } from "./imprint/tools.js";
import { PaperResources } from "./resources/papers.js";
import { DocumentResources } from "./resources/documents.js";

// Configuration
const IMBIB_PORT = Number(process.env.IMBIB_PORT) || 23120;
const IMPRINT_PORT = Number(process.env.IMPRINT_PORT) || 23121;

// ANSI color codes for terminal output
const colors = {
  green: "\x1b[32m",
  red: "\x1b[31m",
  yellow: "\x1b[33m",
  cyan: "\x1b[36m",
  dim: "\x1b[2m",
  reset: "\x1b[0m",
  bold: "\x1b[1m",
};

/**
 * Run connection check and display diagnostic information
 */
async function runCheck(): Promise<void> {
  console.log(`\n${colors.bold}impress-mcp connection check${colors.reset}\n`);

  const imbibClient = new ImbibClient(`http://127.0.0.1:${IMBIB_PORT}`);
  const imprintClient = new ImprintClient(`http://127.0.0.1:${IMPRINT_PORT}`);

  let allGood = true;

  // Check imbib
  const imbibStatus = await imbibClient.checkStatus();
  if (imbibStatus) {
    console.log(
      `${colors.green}✓${colors.reset} imbib HTTP API responding on port ${IMBIB_PORT}`
    );
    console.log(
      `  ${colors.dim}→ Library: ${imbibStatus.libraryCount.toLocaleString()} papers${colors.reset}`
    );
    console.log(
      `  ${colors.dim}→ Collections: ${imbibStatus.collectionCount}${colors.reset}`
    );
  } else {
    allGood = false;
    console.log(
      `${colors.red}✗${colors.reset} imbib HTTP API not responding on port ${IMBIB_PORT}`
    );
    console.log(
      `  ${colors.dim}→ Make sure imbib is running${colors.reset}`
    );
    console.log(
      `  ${colors.dim}→ Enable HTTP Server in Settings → General → Automation${colors.reset}`
    );
  }

  console.log("");

  // Check imprint
  const imprintStatus = await imprintClient.checkStatus();
  if (imprintStatus) {
    console.log(
      `${colors.green}✓${colors.reset} imprint HTTP API responding on port ${IMPRINT_PORT}`
    );
    console.log(
      `  ${colors.dim}→ Open documents: ${imprintStatus.openDocuments}${colors.reset}`
    );
  } else {
    allGood = false;
    console.log(
      `${colors.red}✗${colors.reset} imprint HTTP API not responding on port ${IMPRINT_PORT}`
    );
    console.log(
      `  ${colors.dim}→ Make sure imprint is running${colors.reset}`
    );
    console.log(
      `  ${colors.dim}→ Enable HTTP API in Settings → Automation${colors.reset}`
    );
  }

  console.log("");

  // Show configuration
  const config = {
    mcpServers: {
      impress: {
        command: "npx",
        args: ["impress-mcp"],
      },
    },
  };

  if (allGood) {
    console.log(
      `${colors.green}${colors.bold}Ready!${colors.reset} Add this to your AI tool:\n`
    );
  } else {
    console.log(
      `${colors.yellow}${colors.bold}Partial setup.${colors.reset} Once apps are running, add this to your AI tool:\n`
    );
  }

  console.log(`${colors.cyan}${JSON.stringify(config, null, 2)}${colors.reset}`);

  console.log(`
${colors.dim}Configuration file locations:
  Claude Desktop: ~/Library/Application Support/Claude/claude_desktop_config.json
  Claude Code:    ~/.claude/settings.json (or run: claude mcp add impress npx impress-mcp)
  Cursor:         Settings → MCP → Add Server
  Zed:            Settings → Extensions → MCP${colors.reset}
`);

  process.exit(allGood ? 0 : 1);
}

// Initialize clients
const imbibClient = new ImbibClient(`http://127.0.0.1:${IMBIB_PORT}`);
const imprintClient = new ImprintClient(`http://127.0.0.1:${IMPRINT_PORT}`);

// Initialize tool handlers
const imbibTools = new ImbibTools(imbibClient);
const imprintTools = new ImprintTools(imprintClient);

// Initialize resource handlers
const paperResources = new PaperResources(imbibClient);
const documentResources = new DocumentResources(imprintClient);

// Create server
const server = new Server(
  {
    name: "impress-mcp",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
      resources: {},
    },
  }
);

// List available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [...IMBIB_TOOLS, ...IMPRINT_TOOLS],
  };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    // imbib tools
    if (name.startsWith("imbib_")) {
      return await imbibTools.handleTool(name, args);
    }

    // imprint tools
    if (name.startsWith("imprint_")) {
      return await imprintTools.handleTool(name, args);
    }

    return {
      content: [
        {
          type: "text",
          text: `Unknown tool: ${name}`,
        },
      ],
      isError: true,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      content: [
        {
          type: "text",
          text: `Error executing ${name}: ${message}`,
        },
      ],
      isError: true,
    };
  }
});

// List available resources
server.setRequestHandler(ListResourcesRequestSchema, async () => {
  const imbibResources = await paperResources.list();
  const imprintResourcesList = await documentResources.list();

  return {
    resources: [...imbibResources, ...imprintResourcesList],
  };
});

// Read resource
server.setRequestHandler(ReadResourceRequestSchema, async (request) => {
  const { uri } = request.params;

  try {
    if (uri.startsWith("impress://imbib/")) {
      return await paperResources.read(uri);
    }

    if (uri.startsWith("impress://imprint/")) {
      return await documentResources.read(uri);
    }

    return {
      contents: [
        {
          uri,
          mimeType: "text/plain",
          text: `Unknown resource: ${uri}`,
        },
      ],
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      contents: [
        {
          uri,
          mimeType: "text/plain",
          text: `Error reading resource: ${message}`,
        },
      ],
    };
  }
});

// Main entry point
async function main() {
  // Parse command line arguments
  const args = process.argv.slice(2);

  // Handle --check flag
  if (args.includes("--check") || args.includes("-c")) {
    await runCheck();
    return;
  }

  // Handle --help flag
  if (args.includes("--help") || args.includes("-h")) {
    console.log(`
impress-mcp - MCP Server for imbib and imprint

Usage:
  npx impress-mcp          Run the MCP server (stdio transport)
  npx impress-mcp --check  Test connections and show configuration
  npx impress-mcp --help   Show this help message

Environment Variables:
  IMBIB_PORT     imbib HTTP API port (default: 23120)
  IMPRINT_PORT   imprint HTTP API port (default: 23121)

For setup instructions, see:
  https://imbib.com/docs/MCP-Setup-Guide
`);
    process.exit(0);
  }

  // Check connection to apps
  console.error("impress-mcp starting...");

  const imbibStatus = await imbibClient.checkStatus();
  if (imbibStatus) {
    console.error(`Connected to imbib (${imbibStatus.libraryCount} papers)`);
  } else {
    console.error("Warning: imbib is not running or HTTP API is disabled");
  }

  const imprintStatus = await imprintClient.checkStatus();
  if (imprintStatus) {
    console.error(
      `Connected to imprint (${imprintStatus.openDocuments} documents)`
    );
  } else {
    console.error("Warning: imprint is not running or HTTP API is disabled");
  }

  // Start server with stdio transport
  const transport = new StdioServerTransport();
  await server.connect(transport);

  console.error("impress-mcp server running");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
