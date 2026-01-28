//
//  IOSSketchView.swift
//  imprint-iOS
//
//  Created by Claude on 2026-01-27.
//

import SwiftUI
import PencilKit
import os.log

// MARK: - iOS Sketch View

/// A PencilKit-based drawing canvas for imprint.
///
/// Features:
/// - Full Apple Pencil support with pressure sensitivity
/// - Palm rejection
/// - Export to PNG for insertion into Typst documents
/// - Margin annotation mode for commenting on text
@MainActor
public struct IOSSketchView: View {

    // MARK: - Properties

    /// The drawing data
    @Binding var drawing: PKDrawing

    /// Whether the sketch is for a margin annotation
    let isMarginAnnotation: Bool

    /// Callback when drawing is complete
    var onComplete: ((Data) -> Void)?

    /// Callback when cancelled
    var onCancel: (() -> Void)?

    @State private var canvasView = PKCanvasView()
    @State private var toolPicker = PKToolPicker()

    @Environment(\.dismiss) private var dismiss

    // MARK: - Initialization

    public init(
        drawing: Binding<PKDrawing>,
        isMarginAnnotation: Bool = false,
        onComplete: ((Data) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self._drawing = drawing
        self.isMarginAnnotation = isMarginAnnotation
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            SketchCanvasView(
                canvasView: $canvasView,
                toolPicker: $toolPicker,
                drawing: $drawing
            )
            .background(isMarginAnnotation ? Color.yellow.opacity(0.1) : Color.white)
            .navigationTitle(isMarginAnnotation ? "Annotation" : "Sketch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel?()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            clearCanvas()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }

                        Button {
                            undoLastStroke()
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveAndComplete()
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func clearCanvas() {
        canvasView.drawing = PKDrawing()
        drawing = PKDrawing()
    }

    private func undoLastStroke() {
        canvasView.undoManager?.undo()
        drawing = canvasView.drawing
    }

    private func saveAndComplete() {
        drawing = canvasView.drawing

        // Export as PNG
        if let pngData = exportAsPNG() {
            onComplete?(pngData)
        }

        dismiss()
    }

    private func exportAsPNG() -> Data? {
        let bounds = drawing.bounds
        guard !bounds.isEmpty else { return nil }

        // Add some padding
        let padding: CGFloat = 20
        let imageRect = bounds.insetBy(dx: -padding, dy: -padding)

        // Render to image
        let image = drawing.image(from: imageRect, scale: 2.0)

        return image.pngData()
    }
}

// MARK: - Canvas View Representable

struct SketchCanvasView: UIViewRepresentable {

    @Binding var canvasView: PKCanvasView
    @Binding var toolPicker: PKToolPicker
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.delegate = context.coordinator
        canvasView.drawing = drawing
        canvasView.drawingPolicy = .anyInput // Allow finger and Pencil
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false

        // Configure for Apple Pencil
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 3)

        // Show tool picker
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()

        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Update drawing if changed externally
        if uiView.drawing != drawing {
            uiView.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: SketchCanvasView

        init(_ parent: SketchCanvasView) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}

// MARK: - Sketch Insertion Service

/// Service for managing sketches in imprint documents.
public actor SketchInsertionService {

    private let logger = Logger(subsystem: "com.imbib.imprint", category: "Sketch")

    /// Saves a sketch to the document's assets folder.
    ///
    /// - Parameters:
    ///   - pngData: The PNG data of the sketch
    ///   - documentURL: The URL of the .imprint document
    /// - Returns: The relative path to insert in Typst
    public func saveSketch(_ pngData: Data, to documentURL: URL) throws -> String {
        // Create assets folder if needed
        let assetsURL = documentURL.appendingPathComponent("assets", isDirectory: true)
        if !FileManager.default.fileExists(atPath: assetsURL.path) {
            try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        }

        // Generate unique filename
        let filename = "sketch_\(UUID().uuidString.prefix(8)).png"
        let fileURL = assetsURL.appendingPathComponent(filename)

        // Save the PNG
        try pngData.write(to: fileURL)

        logger.info("Saved sketch: \(filename)")

        // Return relative path for Typst
        return "assets/\(filename)"
    }

    /// Generates Typst code to insert an image.
    ///
    /// - Parameters:
    ///   - path: The relative path to the image
    ///   - width: Optional width constraint
    /// - Returns: Typst code to insert
    public func generateTypstImageCode(path: String, width: String? = nil) -> String {
        if let width = width {
            return "#image(\"\(path)\", width: \(width))"
        } else {
            return "#image(\"\(path)\")"
        }
    }
}

// MARK: - Sketch Button

/// A button that opens the sketch view.
public struct SketchButton: View {

    @State private var isPresented = false
    @State private var drawing = PKDrawing()

    let onSketchComplete: (Data) -> Void

    public init(onSketchComplete: @escaping (Data) -> Void) {
        self.onSketchComplete = onSketchComplete
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Sketch", systemImage: "scribble")
        }
        .sheet(isPresented: $isPresented) {
            IOSSketchView(
                drawing: $drawing,
                onComplete: { data in
                    onSketchComplete(data)
                    drawing = PKDrawing()
                },
                onCancel: {
                    drawing = PKDrawing()
                }
            )
        }
    }
}

// MARK: - Margin Annotation View

/// A simplified sketch view for margin annotations.
public struct MarginAnnotationView: View {

    @State private var drawing = PKDrawing()
    let onComplete: (Data) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    public init(
        onComplete: @escaping (Data) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    public var body: some View {
        IOSSketchView(
            drawing: $drawing,
            isMarginAnnotation: true,
            onComplete: onComplete,
            onCancel: onCancel
        )
        .frame(maxHeight: 200)
    }
}

// MARK: - Preview

#Preview("Sketch View") {
    IOSSketchView(
        drawing: .constant(PKDrawing()),
        onComplete: { _ in },
        onCancel: { }
    )
}

#Preview("Sketch Button") {
    SketchButton { data in
        print("Sketch complete: \(data.count) bytes")
    }
    .padding()
}
