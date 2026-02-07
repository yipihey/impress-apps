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
import { ImpartClient } from "./impart/client.js";
import { ImpartTools, IMPART_TOOLS } from "./impart/tools.js";
import { ImprintClient } from "./imprint/client.js";
import { ImprintTools, IMPRINT_TOOLS } from "./imprint/tools.js";
import { ImpelClient } from "./impel/client.js";
import { ImpelTools, IMPEL_TOOLS } from "./impel/tools.js";
import { PaperResources } from "./resources/papers.js";
import { DocumentResources } from "./resources/documents.js";

// Cross-app bridges
import {
  ALL_BRIDGE_TOOLS,
  CitationBridge,
  ConversationManuscriptBridge,
  ArtifactResolverBridge,
} from "./bridges/index.js";

// On-demand app launcher
import { appForTool, ensureAppRunning, isConnectionError } from "./app-launcher.js";

// Configuration
const IMBIB_PORT = Number(process.env.IMBIB_PORT) || 23120;
const IMPRINT_PORT = Number(process.env.IMPRINT_PORT) || 23121;
const IMPART_PORT = Number(process.env.IMPART_PORT) || 23122;
const IMPEL_PORT = Number(process.env.IMPEL_PORT) || 23123;

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
  const impartClient = new ImpartClient(`http://127.0.0.1:${IMPART_PORT}`);
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

  // Check impart
  const impartStatus = await impartClient.checkStatus();
  if (impartStatus) {
    console.log(
      `${colors.green}✓${colors.reset} impart HTTP API responding on port ${IMPART_PORT}`
    );
    console.log(
      `  ${colors.dim}→ Accounts: ${impartStatus.accounts}${colors.reset}`
    );
  } else {
    allGood = false;
    console.log(
      `${colors.red}✗${colors.reset} impart HTTP API not responding on port ${IMPART_PORT}`
    );
    console.log(
      `  ${colors.dim}→ Make sure impart is running${colors.reset}`
    );
    console.log(
      `  ${colors.dim}→ Enable HTTP Server in Settings → Automation${colors.reset}`
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

  // Check impel
  const impelCheckClient = new ImpelClient(`http://127.0.0.1:${IMPEL_PORT}`);
  const impelStatus = await impelCheckClient.checkStatus();
  if (impelStatus) {
    console.log(
      `${colors.green}✓${colors.reset} impel HTTP API responding on port ${IMPEL_PORT}`
    );
    console.log(
      `  ${colors.dim}→ Threads: ${impelStatus.threads.active} active / ${impelStatus.threads.total} total${colors.reset}`
    );
    console.log(
      `  ${colors.dim}→ Agents: ${impelStatus.agents.total}${colors.reset}`
    );
    console.log(
      `  ${colors.dim}→ Escalations: ${impelStatus.escalations.open} open${colors.reset}`
    );
  } else {
    // impel is optional - don't mark as failure
    console.log(
      `${colors.yellow}○${colors.reset} impel HTTP API not responding on port ${IMPEL_PORT}`
    );
    console.log(
      `  ${colors.dim}→ impel is optional for agent orchestration${colors.reset}`
    );
    console.log(
      `  ${colors.dim}→ Start with: cd crates/impel-server && IMPEL_ADDR=127.0.0.1:23123 cargo run${colors.reset}`
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
const impartClient = new ImpartClient(`http://127.0.0.1:${IMPART_PORT}`);
const imprintClient = new ImprintClient(`http://127.0.0.1:${IMPRINT_PORT}`);
const impelClient = new ImpelClient(`http://127.0.0.1:${IMPEL_PORT}`);

// Initialize tool handlers
const imbibTools = new ImbibTools(imbibClient);
const impartTools = new ImpartTools(impartClient);
const imprintTools = new ImprintTools(imprintClient);
const impelTools = new ImpelTools(impelClient);

// Initialize bridge handlers
const citationBridge = new CitationBridge(imbibClient, imprintClient);
const conversationManuscriptBridge = new ConversationManuscriptBridge(
  impartClient,
  imprintClient
);
const artifactResolverBridge = new ArtifactResolverBridge(
  imbibClient,
  imprintClient,
  impartClient
);

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
    tools: [
      ...IMBIB_TOOLS,
      ...IMPART_TOOLS,
      ...IMPRINT_TOOLS,
      ...IMPEL_TOOLS,
      ...ALL_BRIDGE_TOOLS,
    ],
  };
});

// Dispatch a tool call to the appropriate handler.
async function dispatchTool(
  name: string,
  args: Record<string, unknown> | undefined
): Promise<{ content: Array<{ type: string; text: string }>; isError?: boolean }> {
  // imbib tools
  if (name.startsWith("imbib_")) {
    return await imbibTools.handleTool(name, args);
  }

  // impart tools
  if (name.startsWith("impart_")) {
    return await impartTools.handleTool(name, args);
  }

  // imprint tools
  if (name.startsWith("imprint_")) {
    return await imprintTools.handleTool(name, args);
  }

  // impel tools
  if (name.startsWith("impel_")) {
    return await impelTools.handleTool(name, args);
  }

  // Cross-app bridge tools
  if (name.startsWith("impress_cite")) {
    return await citationBridge.handleTool(name, args);
  }
  if (name.startsWith("impress_conversation") || name === "impress_export_conversation_citations") {
    return await conversationManuscriptBridge.handleTool(name, args);
  }
  if (name.startsWith("impress_resolve") || name === "impress_list_artifacts") {
    return await artifactResolverBridge.handleTool(name, args);
  }

  return {
    content: [{ type: "text", text: `Unknown tool: ${name}` }],
    isError: true,
  };
}

// Handle tool calls — with on-demand app launching on connection failure.
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    return await dispatchTool(name, args);
  } catch (error) {
    // If the app isn't running, try to launch it and retry once
    if (isConnectionError(error)) {
      const app = appForTool(name);
      if (app) {
        const launched = await ensureAppRunning(app);
        if (launched) {
          try {
            return await dispatchTool(name, args);
          } catch (retryError) {
            const msg = retryError instanceof Error ? retryError.message : String(retryError);
            return {
              content: [{ type: "text", text: `Error executing ${name} (after launching ${app}): ${msg}` }],
              isError: true,
            };
          }
        }
      }
    }

    const message = error instanceof Error ? error.message : String(error);
    return {
      content: [{ type: "text", text: `Error executing ${name}: ${message}` }],
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
impress-mcp - MCP Server for imbib, impart, imprint, and impel

Usage:
  npx impress-mcp          Run the MCP server (stdio transport)
  npx impress-mcp --check  Test connections and show configuration
  npx impress-mcp --help   Show this help message

Environment Variables:
  IMBIB_PORT     imbib HTTP API port (default: 23120)
  IMPRINT_PORT   imprint HTTP API port (default: 23121)
  IMPART_PORT    impart HTTP API port (default: 23122)
  IMPEL_PORT     impel HTTP API port (default: 23123)

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

  const impartStatus = await impartClient.checkStatus();
  if (impartStatus) {
    console.error(
      `Connected to impart (${impartStatus.accounts} accounts)`
    );
  } else {
    console.error("Warning: impart is not running or HTTP API is disabled");
  }

  const imprintStatus = await imprintClient.checkStatus();
  if (imprintStatus) {
    console.error(
      `Connected to imprint (${imprintStatus.openDocuments} documents)`
    );
  } else {
    console.error("Warning: imprint is not running or HTTP API is disabled");
  }

  const impelStatus = await impelClient.checkStatus();
  if (impelStatus) {
    console.error(
      `Connected to impel (${impelStatus.threads.total} threads, ${impelStatus.agents.total} agents)`
    );
  } else {
    console.error("Note: impel is not running (optional for agent orchestration)");
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
