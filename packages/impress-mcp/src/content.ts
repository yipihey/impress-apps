/**
 * Shared MCP tool-result content types.
 *
 * Tool results were text-only for the server's whole life, which meant every
 * visual capability in the suite dead-ended: `imprint_get_pdf` fetched the PDF
 * bytes and returned their *filesize*, and the implore exporters serialised
 * real base64 PNGs into text blocks — spending the context of an image while
 * displaying nothing.
 *
 * That is fine when the agent sits at the user's Mac and can open a file path.
 * It is useless in the target workflow, where the user is on a phone and the
 * conversation is the only display surface. Tools that produce something
 * viewable must return it as an image block.
 */

/** A plain text block — the default for every non-visual result. */
export type TextContent = {
  type: "text";
  text: string;
};

/**
 * An image block. `data` is raw base64 (NO `data:` URI prefix — the MCP
 * client adds its own framing), and `mimeType` must be a real image type.
 * SVG is deliberately NOT an image block: MCP image content is raster, and
 * most clients will not render `image/svg+xml`. Send SVG as text.
 */
export type ImageContent = {
  type: "image";
  data: string;
  mimeType: string;
};

export type ToolContent = TextContent | ImageContent;

export type ToolResult = {
  content: ToolContent[];
  isError?: boolean;
};

/** Convenience: a result that is a single text block. */
export function text(body: string): ToolResult {
  return { content: [{ type: "text", text: body }] };
}

/**
 * A viewable image plus a caption describing it.
 *
 * Always pair an image with text: the caption carries the identifiers
 * (figure id, document id, page count, path on disk) that the agent needs for
 * follow-up calls and that the user needs to refer to the thing in words.
 * An image alone is unaddressable in a conversation.
 */
export function imageWithCaption(
  base64: string,
  mimeType: string,
  caption: string
): ToolResult {
  return {
    content: [
      { type: "image", data: base64, mimeType },
      { type: "text", text: caption },
    ],
  };
}

/** Normalise a base64 payload that may arrive as a `data:` URI. */
export function stripDataURI(data: string): string {
  const comma = data.indexOf(",");
  return data.startsWith("data:") && comma !== -1 ? data.slice(comma + 1) : data;
}

/** Base64-encode binary bytes from a fetch (`ArrayBuffer`/`Uint8Array`). */
export function toBase64(bytes: ArrayBuffer | Uint8Array): string {
  const buf = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  return Buffer.from(buf).toString("base64");
}

/**
 * Guard against returning an image so large it blows the conversation budget.
 * Base64 inflates by ~4/3, so a 4MB cap is ~5.5MB on the wire. Over the cap,
 * callers should fall back to a text description plus a path.
 */
export const MAX_INLINE_IMAGE_BYTES = 4 * 1024 * 1024;

export function isInlineable(base64: string): boolean {
  return base64.length <= MAX_INLINE_IMAGE_BYTES;
}
