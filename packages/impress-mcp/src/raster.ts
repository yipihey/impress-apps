/**
 * PDF page rasterisation, with no npm dependency.
 *
 * MCP image content is raster only, so a PDF can never be returned directly.
 * The target workflow — the user on a phone, the agent on the Mac, the
 * conversation as the only display surface — needs the page as a PNG or the
 * result is unviewable.
 *
 * Rather than pull in a PDF renderer (pdfjs + canvas is tens of megabytes and
 * a native build), this shells out to `osascript -l JavaScript`, which is part
 * of macOS and has a bridge to PDFKit/AppKit. The whole suite is macOS-native,
 * and the MCP server always runs on the user's Mac even when imbib itself is
 * remote (the phone), so the bytes are always rasterisable locally.
 *
 * Every failure path returns `{ ok: false }` — never throws — so callers can
 * degrade to text plus an on-disk path instead of losing the tool call.
 */

import { execFile } from "child_process";
import { promisify } from "util";
import { mkdir, writeFile, readFile, unlink } from "fs/promises";
import { tmpdir } from "os";
import { join } from "path";

const execFileAsync = promisify(execFile);

/** Longest edge, in pixels, of a rendered page. ~1100px stays readable for
 * body text while keeping a typical page well under MAX_INLINE_IMAGE_BYTES. */
export const DEFAULT_PAGE_MAX_DIM = 1100;

/** Where rasterised inputs are parked so captions can quote a real path. */
export function rasterScratchDir(): string {
  return join(tmpdir(), "impress-mcp");
}

export type RasterSuccess = {
  ok: true;
  /** Raw base64 PNG, no data: URI prefix. */
  base64: string;
  /** Decoded PNG size in bytes. */
  byteLength: number;
  pageCount: number;
  /** 1-based page actually rendered (clamped into range). */
  page: number;
  width: number;
  height: number;
  /** The source PDF on disk — useful to an agent that can open files. */
  pdfPath: string;
};

export type RasterFailure = {
  ok: false;
  error: string;
  pdfPath?: string;
};

export type RasterResult = RasterSuccess | RasterFailure;

/**
 * JXA: open the PDF with PDFKit, render one page to PNG, report the page
 * count. `boundsForBox(0)` is kPDFDisplayBoxMediaBox; `4` is
 * NSBitmapImageFileTypePNG — the named constants are not on the JXA bridge.
 */
const RASTER_JXA = `
function run(argv) {
  ObjC.import('Foundation');
  ObjC.import('AppKit');
  ObjC.import('Quartz');
  var inPath = argv[0], outPath = argv[1];
  var pageArg = parseInt(argv[2], 10) || 1;
  var maxDim = parseInt(argv[3], 10) || 1100;

  var doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath($(inPath)));
  if (!doc || doc.isNil()) return JSON.stringify({ error: 'not a readable PDF' });
  var count = parseInt(doc.pageCount, 10);
  if (!count) return JSON.stringify({ error: 'PDF has no pages' });
  var idx = pageArg < 1 ? 1 : (pageArg > count ? count : pageArg);
  var page = doc.pageAtIndex(idx - 1);
  if (!page || page.isNil()) return JSON.stringify({ error: 'page ' + idx + ' not readable' });

  var bounds = page.boundsForBox(0);
  var w = bounds.size.width, h = bounds.size.height;
  if (!w || !h) return JSON.stringify({ error: 'page has zero bounds' });
  var scale = Math.min(maxDim / w, maxDim / h, 4);
  if (!isFinite(scale) || scale <= 0) scale = 1;
  var tw = Math.max(1, Math.round(w * scale)), th = Math.max(1, Math.round(h * scale));

  var img = page.thumbnailOfSizeForBox({ width: tw, height: th }, 0);
  var rep = $.NSBitmapImageRep.imageRepWithData(img.TIFFRepresentation);
  var png = rep.representationUsingTypeProperties(4, $());
  if (!png || png.isNil()) return JSON.stringify({ error: 'PNG encoding failed' });
  png.writeToFileAtomically($(outPath), true);
  return JSON.stringify({ pageCount: count, page: idx, width: tw, height: th });
}
`;

/**
 * Render one page of a PDF to PNG.
 *
 * @param pdf   the PDF bytes (as returned by `response.arrayBuffer()`)
 * @param opts.page     1-based page number, clamped to the document (default 1)
 * @param opts.maxDim   longest edge in pixels (default DEFAULT_PAGE_MAX_DIM)
 * @param opts.basename slug used for the scratch filenames
 */
export async function rasterizePDFPage(
  pdf: ArrayBuffer | Uint8Array,
  opts: { page?: number; maxDim?: number; basename?: string } = {}
): Promise<RasterResult> {
  const page = Math.max(1, Math.floor(opts.page ?? 1));
  const maxDim = opts.maxDim ?? DEFAULT_PAGE_MAX_DIM;
  const slug = (opts.basename ?? "document").replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 64);

  const dir = rasterScratchDir();
  const pdfPath = join(dir, `${slug}.pdf`);
  const pngPath = join(dir, `${slug}-p${page}.png`);

  try {
    await mkdir(dir, { recursive: true });
    const bytes = pdf instanceof Uint8Array ? pdf : new Uint8Array(pdf);
    await writeFile(pdfPath, bytes);
  } catch (error) {
    return { ok: false, error: `could not stage the PDF: ${messageOf(error)}` };
  }

  let meta: { pageCount?: number; page?: number; width?: number; height?: number; error?: string };
  try {
    const { stdout } = await execFileAsync(
      "osascript",
      ["-l", "JavaScript", "-e", RASTER_JXA, pdfPath, pngPath, String(page), String(maxDim)],
      { timeout: 30_000 }
    );
    meta = JSON.parse(stdout.trim() || "{}");
  } catch (error) {
    // Missing osascript (non-macOS host) or a JXA error both land here.
    return { ok: false, error: `PDF rasterisation failed: ${messageOf(error)}`, pdfPath };
  }

  if (meta.error) return { ok: false, error: meta.error, pdfPath };

  try {
    const png = await readFile(pngPath);
    await unlink(pngPath).catch(() => {});
    return {
      ok: true,
      base64: png.toString("base64"),
      byteLength: png.byteLength,
      pageCount: meta.pageCount ?? 1,
      page: meta.page ?? page,
      width: meta.width ?? 0,
      height: meta.height ?? 0,
      pdfPath,
    };
  } catch (error) {
    return { ok: false, error: `rendered page could not be read back: ${messageOf(error)}`, pdfPath };
  }
}

function messageOf(error: unknown): string {
  if (error instanceof Error) return error.message.trim();
  return String(error);
}
