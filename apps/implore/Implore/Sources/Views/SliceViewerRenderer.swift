import ImpressLogging
import MetalKit
import OSLog

/// Metal renderer for displaying pre-colormapped 2D slices.
///
/// The colormap is applied CPU-side in Rust. This renderer just uploads
/// RGBA bytes as a texture and draws a fullscreen quad with nearest-neighbor
/// sampling so scientists can see individual grid cells.
final class SliceViewerRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private(set) var texture: MTLTexture?
    private let logger = Logger(subsystem: "com.impress.implore", category: "slice-renderer")

    init(device: MTLDevice) throws {
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw RendererError.initFailed("Failed to create command queue")
        }
        self.commandQueue = queue

        // Load shader library from the app bundle (compiled by Xcode)
        guard let library = device.makeDefaultLibrary() else {
            throw RendererError.initFailed("Failed to load Metal shader library")
        }

        guard let vertexFunc = library.makeFunction(name: "slice_vertex"),
              let fragFunc = library.makeFunction(name: "slice_fragment") else {
            throw RendererError.initFailed("Failed to load slice shader functions")
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragFunc
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)

        logger.infoCapture("SliceViewerRenderer initialized", category: "slice-renderer")
    }

    /// Upload RGBA pixel data as a Metal texture.
    ///
    /// Creates or replaces the texture if dimensions changed.
    func updateTexture(rgbaBytes: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let expectedLen = width * height * 4
        guard rgbaBytes.count == expectedLen else {
            logger.warningCapture("Texture data size mismatch: expected \(expectedLen), got \(rgbaBytes.count)", category: "slice-renderer")
            return
        }

        // Reuse texture if dimensions match
        if let tex = texture, tex.width == width, tex.height == height {
            tex.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: width, height: height, depth: 1)
                ),
                mipmapLevel: 0,
                withBytes: rgbaBytes,
                bytesPerRow: width * 4
            )
            return
        }

        // Create new texture
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead

        guard let tex = device.makeTexture(descriptor: desc) else {
            logger.errorCapture("Failed to create \(width)x\(height) texture", category: "slice-renderer")
            return
        }

        tex.replace(
            region: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)
            ),
            mipmapLevel: 0,
            withBytes: rgbaBytes,
            bytesPerRow: width * 4
        )

        self.texture = tex
        logger.infoCapture("Created slice texture \(width)x\(height)", category: "slice-renderer")
    }

    /// Draw the slice texture as a fullscreen quad.
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let texture = self.texture else {
            return
        }

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    enum RendererError: Error {
        case initFailed(String)
    }
}
