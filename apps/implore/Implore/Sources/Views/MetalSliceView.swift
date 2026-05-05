import ImpressLogging
import MetalKit
import SwiftUI

/// NSViewRepresentable wrapping an MTKView for slice texture display.
///
/// Uses `enableSetNeedsDisplay = true` and `isPaused = true` so the view
/// only redraws when slice data changes, not at 60fps.
struct MetalSliceView: NSViewRepresentable {
    let viewerState: RgViewerState

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        view.delegate = context.coordinator
        // Only redraw when we call setNeedsDisplay, not continuously
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        context.coordinator.metalView = view
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let coord = context.coordinator
        // Only upload + redraw when sliceVersion changed
        if coord.lastSliceVersion != viewerState.sliceVersion {
            coord.lastSliceVersion = viewerState.sliceVersion
            if let slice = viewerState.currentSlice {
                let bytes = Array(slice.rgbaBytes)
                coord.renderer?.updateTexture(
                    rgbaBytes: bytes,
                    width: Int(slice.width),
                    height: Int(slice.height)
                )
            }
            view.setNeedsDisplay(view.bounds)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: SliceViewerRenderer?
        weak var metalView: MTKView?
        var lastSliceVersion: Int = -1

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Initialize renderer on first drawable (ensures device is set)
            if renderer == nil, let device = view.device {
                do {
                    renderer = try SliceViewerRenderer(device: device)
                } catch {
                    logError("SliceViewerRenderer init failed: \(error)", category: "slice-renderer")
                }
            }
        }

        func draw(in view: MTKView) {
            renderer?.draw(in: view)
        }
    }
}
