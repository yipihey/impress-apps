import ImpressKeyboard
import SwiftUI

/// Main view for the RG volume slice viewer.
///
/// Combines the Metal slice rendering with an info bar and keyboard navigation.
/// Keys: `[`/`]` navigate slices, `q` cycle quantity, `a` cycle axis,
/// `c` cycle colormap, `x`/`y`/`z` set axis directly.
struct RgSliceView: View {
    let viewerState: RgViewerState

    var body: some View {
        VStack(spacing: 0) {
            MetalSliceView(viewerState: viewerState)
                .accessibilityIdentifier("rg.metalSliceView")

            SliceInfoBar(viewerState: viewerState)
                .accessibilityIdentifier("rg.infoBar")
        }
        .focusable()
        .focusEffectDisabled()
        .keyboardGuarded { press in
            handleKey(press)
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.characters {
        case "[":
            viewerState.previousSlice()
            return .handled
        case "]":
            viewerState.nextSlice()
            return .handled
        case "q":
            viewerState.cycleQuantity()
            return .handled
        case "a":
            viewerState.cycleAxis()
            return .handled
        case "x":
            viewerState.setAxis("x")
            return .handled
        case "y":
            viewerState.setAxis("y")
            return .handled
        case "z":
            viewerState.setAxis("z")
            return .handled
        case "c":
            viewerState.cycleColormap()
            return .handled
        default:
            return .ignored
        }
    }
}
