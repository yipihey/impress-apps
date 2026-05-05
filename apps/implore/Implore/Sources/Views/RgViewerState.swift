import ImploreRustCore
import ImpressLogging
import OSLog

/// Observable state for the RG volume slice viewer.
///
/// Wraps `RgDatasetHandle` (Rust FFI) and manages the current slice
/// parameters: quantity, axis, position, colormap. Provides navigation
/// methods that the keyboard handler and UI controls call.
@MainActor @Observable
final class RgViewerState {
    let dataset: RgDatasetHandle
    private(set) var info: RgDatasetInfo
    var quantity: String
    var axis: String = "z"
    var slicePosition: Int = 0
    var colormap: String = "coolwarm"

    /// Current slice data (nil until first update)
    private(set) var currentSlice: SliceData?

    /// Monotonically increasing version, bumped on each slice update.
    /// Used by MetalSliceView to gate texture uploads.
    private(set) var sliceVersion: Int = 0

    /// Available colormap names (sourced from Rust `builtin_colormap_names`).
    nonisolated static let availableColormaps = ImploreRustCore.availableColormaps()

    private let logger = Logger(subsystem: "com.impress.implore", category: "rg-viewer")

    init(dataset: RgDatasetHandle) {
        self.dataset = dataset
        let info = dataset.info()
        self.info = info

        // Default to first available quantity
        self.quantity = info.availableQuantities.first ?? "velocity_magnitude"

        // Start at midpoint of volume
        let mid = Int(info.gridSize) / 2
        self.slicePosition = mid

        logger.infoCapture("RgViewerState: grid=\(info.gridSize), levels=\(info.levels), quantities=\(info.availableQuantities.joined(separator: ","))", category: "rg-viewer")

        updateSlice()
    }

    /// Recompute the current slice from Rust and update state.
    func updateSlice() {
        do {
            let slice = try dataset.getSlice(
                quantity: quantity,
                axis: axis,
                position: UInt32(slicePosition),
                colormap: colormap
            )
            currentSlice = slice
            sliceVersion += 1
            logger.infoCapture("Slice: \(self.quantity) \(self.axis)=\(self.slicePosition) [\(String(format: "%.4f", slice.minValue)), \(String(format: "%.4f", slice.maxValue))] \(slice.width)x\(slice.height)", category: "rg-viewer")
        } catch {
            logError("Failed to get slice: \(error)", category: "rg-viewer")
        }
    }

    /// Navigate forward through the volume.
    func nextSlice() {
        let max = Int(info.gridSize) - 1
        if slicePosition < max {
            slicePosition += 1
            updateSlice()
        }
    }

    /// Navigate backward through the volume.
    func previousSlice() {
        if slicePosition > 0 {
            slicePosition -= 1
            updateSlice()
        }
    }

    /// Jump to a specific position.
    func setPosition(_ pos: Int) {
        let clamped = max(0, min(pos, Int(info.gridSize) - 1))
        if clamped != slicePosition {
            slicePosition = clamped
            updateSlice()
        }
    }

    /// Cycle through available quantities.
    func cycleQuantity() {
        let qs = info.availableQuantities
        guard !qs.isEmpty else { return }
        if let idx = qs.firstIndex(of: quantity) {
            quantity = qs[(idx + 1) % qs.count]
        } else {
            quantity = qs[0]
        }
        updateSlice()
    }

    /// Set a specific axis (resets position to midpoint).
    func setAxis(_ newAxis: String) {
        guard ["x", "y", "z"].contains(newAxis), newAxis != axis else { return }
        axis = newAxis
        slicePosition = Int(info.gridSize) / 2
        updateSlice()
    }

    /// Cycle through axes: x → y → z → x.
    func cycleAxis() {
        switch axis {
        case "x": setAxis("y")
        case "y": setAxis("z")
        default: setAxis("x")
        }
    }

    /// Cycle through colormaps.
    func cycleColormap() {
        let maps = Self.availableColormaps
        if let idx = maps.firstIndex(of: colormap) {
            colormap = maps[(idx + 1) % maps.count]
        } else {
            colormap = maps[0]
        }
        updateSlice()
    }
}
