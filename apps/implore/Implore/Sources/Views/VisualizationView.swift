import SwiftUI
import MetalKit

/// Main visualization view that hosts the Metal renderer
struct VisualizationView: View {
    let session: VisualizationSession
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(spacing: 0) {
            // Metal rendering view - takes available space
            #if DEBUG
            // Use placeholder for UI testing to avoid Metal/accessibility conflicts
            if CommandLine.arguments.contains("--ui-testing") {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        VStack {
                            Image(systemName: "chart.dots.scatter")
                                .font(.system(size: 60))
                            Text("Visualization Placeholder")
                                .font(.title2)
                            Text(session.name)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("visualization.metalView")
            } else {
                MetalVisualizationView(session: session, renderMode: appState.renderMode)
                    .accessibilityIdentifier("visualization.metalView")
            }
            #else
            MetalVisualizationView(session: session, renderMode: appState.renderMode)
                .accessibilityIdentifier("visualization.metalView")
            #endif

            // Bottom bar with marginals and status
            HStack {
                // Marginals panel (ECDF/PCDF)
                MarginalsPanel()
                    .frame(width: 200, height: 100)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("visualization.marginalsPanel")

                Spacer()

                // Status bar
                StatusBar(session: session)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

/// Metal-backed visualization view
struct MetalVisualizationView: NSViewRepresentable {
    let session: VisualizationSession
    let renderMode: RenderMode

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        view.delegate = context.coordinator
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderMode = renderMode
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var parent: MetalVisualizationView
        var renderMode: RenderMode
        var renderer: VisualizationRenderer?

        init(_ parent: MetalVisualizationView) {
            self.parent = parent
            self.renderMode = parent.renderMode
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle resize
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else {
                return
            }

            // Render based on mode
            // This would call into the Rust core or Metal shaders
        }
    }
}

/// Placeholder renderer class
class VisualizationRenderer {
    // Metal pipeline state, buffers, etc.
}

/// Marginals panel showing ECDF/PCDF statistics
struct MarginalsPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Marginals")
                .font(.caption)
                .fontWeight(.semibold)

            // Placeholder for ECDF plot
            Rectangle()
                .fill(.secondary.opacity(0.2))
                .overlay {
                    Text("ECDF")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
        .padding(8)
    }
}

/// Status bar showing current state
struct StatusBar: View {
    let session: VisualizationSession
    @Environment(AppState.self) var appState

    private var statusString: String {
        "\(session.pointCount) points | Mode: \(appState.renderMode.rawValue) | Selection: none"
    }

    var body: some View {
        // Use Text with the full status to ensure it's accessible
        Text(statusString)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityIdentifier("visualization.statusBar")
    }
}

#Preview {
    VisualizationView(session: VisualizationSession(name: "Test"))
        .environment(AppState())
}
