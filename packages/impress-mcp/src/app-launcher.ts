/**
 * On-demand launcher for impress suite apps.
 *
 * When an MCP tool call fails because the target app isn't running,
 * this module launches it via `open -b <bundleID>` and waits for
 * the HTTP API to become available before retrying.
 */

import { execSync } from "child_process";

interface AppConfig {
  bundleID: string;
  port: number;
  name: string;
}

const APP_CONFIG: Record<string, AppConfig> = {
  imbib: {
    bundleID: "com.imbib.app.ios",
    port: Number(process.env.IMBIB_PORT) || 23120,
    name: "imbib",
  },
  impart: {
    bundleID: "com.imbib.impart",
    port: Number(process.env.IMPART_PORT) || 23122,
    name: "impart",
  },
  imprint: {
    bundleID: "com.imbib.imprint",
    port: Number(process.env.IMPRINT_PORT) || 23121,
    name: "imprint",
  },
  implore: {
    bundleID: "com.impress.implore",
    port: Number(process.env.IMPLORE_PORT) || 23124,
    name: "implore",
  },
};

/** Map tool name prefix to app name. */
export function appForTool(toolName: string): string | undefined {
  if (toolName.startsWith("imbib_")) return "imbib";
  if (toolName.startsWith("impart_")) return "impart";
  if (toolName.startsWith("imprint_")) return "imprint";
  if (toolName.startsWith("implore_")) return "implore";
  return undefined;
}

/** Check if an app's HTTP API is responding. */
async function isAppRunning(app: AppConfig): Promise<boolean> {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 2000);
    const response = await fetch(`http://127.0.0.1:${app.port}/api/status`, {
      signal: controller.signal,
    });
    clearTimeout(timeout);
    return response.ok;
  } catch {
    return false;
  }
}

/** Wait for an app's HTTP API to become available. */
async function waitForApp(
  app: AppConfig,
  maxWaitMs: number = 15000
): Promise<boolean> {
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    if (await isAppRunning(app)) return true;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  return false;
}

/** Track which apps we've already tried to launch this session. */
const launchAttempted = new Set<string>();

/**
 * Ensure an app is running. If not, launch it and wait for the HTTP API.
 * Returns true if the app is available, false if launch failed.
 */
export async function ensureAppRunning(appName: string): Promise<boolean> {
  const config = APP_CONFIG[appName];
  if (!config) return false;

  // Already running?
  if (await isAppRunning(config)) return true;

  // Already tried and failed this session?
  if (launchAttempted.has(appName)) return false;
  launchAttempted.add(appName);

  // Launch via macOS open command
  console.error(`Launching ${config.name} (${config.bundleID})...`);
  try {
    execSync(`open -b ${config.bundleID} --background`, { timeout: 5000 });
  } catch (error) {
    console.error(`Failed to launch ${config.name}: ${error}`);
    return false;
  }

  // Wait for HTTP API
  const ready = await waitForApp(config);
  if (ready) {
    console.error(`${config.name} is now running on port ${config.port}`);
    // Clear the attempt flag so we can re-launch if it crashes later
    launchAttempted.delete(appName);
  } else {
    console.error(
      `${config.name} launched but HTTP API not responding after 15s`
    );
  }
  return ready;
}

/**
 * Check whether an error means "nothing is listening" (so launching the app
 * is worth a try) as opposed to "the app answered and said no".
 *
 * This must be tight. A loose substring match — the old `msg.includes("connect")`
 * — fires on ordinary application errors ("could not connect the figure to a
 * document", "disconnected participant"), which then launches an app the user
 * did not ask for and retries a call that was never going to succeed.
 * Prefer matching the transport-level codes, which Node puts on the error
 * itself or on `cause`.
 */
const CONNECTION_ERROR_CODES = new Set([
  "ECONNREFUSED",
  "ECONNRESET",
  "ENOTFOUND",
  "EHOSTUNREACH",
  "EHOSTDOWN",
  "ENETUNREACH",
  "ENETDOWN",
  "EAI_AGAIN",
  "ETIMEDOUT",
  "UND_ERR_CONNECT_TIMEOUT",
  "UND_ERR_SOCKET",
]);

export function isConnectionError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;

  // Node's fetch wraps the real cause: TypeError("fetch failed") { cause: Error { code } }.
  for (let current: unknown = error, depth = 0; current instanceof Error && depth < 4; depth++) {
    const code = (current as NodeJS.ErrnoException).code;
    if (typeof code === "string" && CONNECTION_ERROR_CODES.has(code.toUpperCase())) {
      return true;
    }
    current = (current as { cause?: unknown }).cause;
  }

  // Fall back to whole-phrase matches on the message. These are emitted
  // verbatim by fetch/undici and by this package's own clients; none of them
  // occur in an application-level error message.
  const msg = error.message.toLowerCase();
  return (
    msg.includes("fetch failed") ||
    msg.includes("econnrefused") ||
    msg.includes("connection refused") ||
    msg.includes("connect timeout") ||
    msg.includes("network request failed") ||
    msg.includes("is not running")
  );
}
