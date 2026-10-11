// The surface session lives in ImpressSurfaceSession so iOS can open a
// generated surface without linking this macOS-only package. Re-exported so
// a macOS host that already imports ImpressLayout still sees
// `SurfacePaneModel`, and so the Sendable conformances stay the one copy.
@_exported import ImpressSurfaceSession
