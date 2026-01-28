//
//  HelixTextEditor.swift
//  ImpelHelixCore
//
//  SwiftUI wrapper for text editing with Helix support.
//

import SwiftUI

#if canImport(AppKit)
import AppKit

/// A SwiftUI text editor with Helix modal editing support for macOS.
public struct HelixTextEditor: View {
    @Binding public var text: String
    @ObservedObject public var helixState: HelixState
    public var isHelixEnabled: Bool
    public var showModeIndicator: Bool
    public var indicatorPosition: ModeIndicatorPosition
    public var font: NSFont

    public init(
        text: Binding<String>,
        helixState: HelixState,
        isHelixEnabled: Bool = true,
        showModeIndicator: Bool = false,
        indicatorPosition: ModeIndicatorPosition = .bottomLeft,
        font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    ) {
        self._text = text
        self.helixState = helixState
        self.isHelixEnabled = isHelixEnabled
        self.showModeIndicator = showModeIndicator
        self.indicatorPosition = indicatorPosition
        self.font = font
    }

    public var body: some View {
        HelixTextEditorRepresentable(
            text: $text,
            helixState: helixState,
            isHelixEnabled: isHelixEnabled,
            font: font
        )
        .helixModeIndicator(
            state: helixState,
            position: indicatorPosition,
            isVisible: isHelixEnabled && showModeIndicator
        )
    }
}

/// Internal NSViewRepresentable for the actual text view
struct HelixTextEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var helixState: HelixState
    var isHelixEnabled: Bool
    var font: NSFont

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = HelixTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = font
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor

        // Configure text container
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        // Set up Helix adaptor
        let adaptor = NSTextViewHelixAdaptor(textView: textView, helixState: helixState)
        adaptor.isEnabled = isHelixEnabled
        textView.helixAdaptor = adaptor
        context.coordinator.helixAdaptor = adaptor

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Set initial text
        textView.string = text

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? HelixTextView else { return }

        // Update Helix enabled state
        context.coordinator.helixAdaptor?.isEnabled = isHelixEnabled

        // Update text if changed externally
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            if selectedRange.location <= text.count {
                textView.setSelectedRange(selectedRange)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: HelixTextView?
        weak var helixAdaptor: NSTextViewHelixAdaptor?

        init(text: Binding<String>) {
            self._text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
#endif

#if canImport(UIKit)
import UIKit

/// A SwiftUI text editor with Helix modal editing support for iOS.
///
/// Note: iOS support is limited as UITextView doesn't easily support
/// key event interception. Full Helix support requires hardware keyboard.
public struct HelixTextEditor: View {
    @Binding public var text: String
    @ObservedObject public var helixState: HelixState
    public var isHelixEnabled: Bool
    public var showModeIndicator: Bool
    public var indicatorPosition: ModeIndicatorPosition
    public var font: UIFont

    public init(
        text: Binding<String>,
        helixState: HelixState,
        isHelixEnabled: Bool = true,
        showModeIndicator: Bool = false,
        indicatorPosition: ModeIndicatorPosition = .bottomLeft,
        font: UIFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    ) {
        self._text = text
        self.helixState = helixState
        self.isHelixEnabled = isHelixEnabled
        self.showModeIndicator = showModeIndicator
        self.indicatorPosition = indicatorPosition
        self.font = font
    }

    public var body: some View {
        HelixTextEditorRepresentable(
            text: $text,
            helixState: helixState,
            isHelixEnabled: isHelixEnabled,
            font: font
        )
        .helixModeIndicator(
            state: helixState,
            position: indicatorPosition,
            isVisible: isHelixEnabled && showModeIndicator
        )
    }
}

/// Internal UIViewRepresentable for the actual text view
struct HelixTextEditorRepresentable: UIViewRepresentable {
    @Binding var text: String
    @ObservedObject var helixState: HelixState
    var isHelixEnabled: Bool
    var font: UIFont

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = font
        textView.backgroundColor = .systemBackground
        textView.textColor = .label
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            self._text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}
#endif
