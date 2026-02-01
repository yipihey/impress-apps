//
//  IOSSketchAnnotationView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-28.
//

import SwiftUI
import PencilKit
import PDFKit
import os.log

private let sketchLogger = Logger(subsystem: "com.imbib.app", category: "sketch")

// MARK: - iOS Sketch Annotation View

/// A PencilKit-based drawing canvas for PDF annotations.
///
/// Features:
/// - Full Apple Pencil support with pressure sensitivity
/// - Palm rejection
/// - Export to PNG for embedding in PDF
/// - Undo/redo support
/// - Tool picker integration
@MainActor
public struct IOSSketchAnnotationView: View {

    // MARK: - Properties

    /// The drawing data
    @Binding var drawing: PKDrawing

    /// The page being annotated (for bounds calculation)
    let pageSize: CGSize

    /// Callback when drawing is complete
    var onComplete: ((Data, CGRect) -> Void)?

    /// Callback when cancelled
    var onCancel: (() -> Void)?

    @State private var canvasView = PKCanvasView()
    @State private var toolPicker = PKToolPicker()

    @Environment(\.dismiss) private var dismiss

    // MARK: - Initialization

    public init(
        drawing: Binding<PKDrawing>,
        pageSize: CGSize,
        onComplete: ((Data, CGRect) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self._drawing = drawing
        self.pageSize = pageSize
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            SketchAnnotationCanvasView(
                canvasView: $canvasView,
                toolPicker: $toolPicker,
                drawing: $drawing
            )
            .background(Color.white)
            .navigationTitle("Draw Annotation")
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

                        Button {
                            redoStroke()
                        } label: {
                            Label("Redo", systemImage: "arrow.uturn.forward")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saveAndComplete()
                    }
                    .disabled(drawing.bounds.isEmpty)
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

    private func redoStroke() {
        canvasView.undoManager?.redo()
        drawing = canvasView.drawing
    }

    private func saveAndComplete() {
        drawing = canvasView.drawing

        // Export as PNG
        if let pngData = exportAsPNG() {
            let bounds = drawing.bounds
            sketchLogger.info("Sketch completed: \(Int(bounds.width))x\(Int(bounds.height))")
            onComplete?(pngData, bounds)
        }

        dismiss()
    }

    private func exportAsPNG() -> Data? {
        let bounds = drawing.bounds
        guard !bounds.isEmpty else { return nil }

        // Add some padding
        let padding: CGFloat = 10
        let imageRect = bounds.insetBy(dx: -padding, dy: -padding)

        // Render to image
        let image = drawing.image(from: imageRect, scale: 2.0)

        return image.pngData()
    }
}

// MARK: - Canvas View Representable

struct SketchAnnotationCanvasView: UIViewRepresentable {

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
        var parent: SketchAnnotationCanvasView

        init(_ parent: SketchAnnotationCanvasView) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}

// MARK: - Sketch Annotation Button

/// A button that opens the sketch annotation view.
public struct SketchAnnotationButton: View {

    @State private var isPresented = false
    @State private var drawing = PKDrawing()

    let pageSize: CGSize
    let onSketchComplete: (Data, CGRect) -> Void

    public init(
        pageSize: CGSize,
        onSketchComplete: @escaping (Data, CGRect) -> Void
    ) {
        self.pageSize = pageSize
        self.onSketchComplete = onSketchComplete
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Sketch", systemImage: "scribble")
        }
        .sheet(isPresented: $isPresented) {
            IOSSketchAnnotationView(
                drawing: $drawing,
                pageSize: pageSize,
                onComplete: { data, bounds in
                    onSketchComplete(data, bounds)
                    drawing = PKDrawing()
                },
                onCancel: {
                    drawing = PKDrawing()
                }
            )
        }
    }
}

// MARK: - Sketch Annotation Service

/// Service for managing sketch annotations on PDFs.
@MainActor
public final class SketchAnnotationService {

    // MARK: - Singleton

    public static let shared = SketchAnnotationService()

    private init() {}

    // MARK: - Add Sketch Annotation

    /// Add a sketch as an ink annotation to a PDF page.
    ///
    /// - Parameters:
    ///   - pngData: The PNG image data of the sketch
    ///   - bounds: The bounds of the sketch in canvas coordinates
    ///   - page: The PDF page to add the annotation to
    ///   - pagePoint: The location in page coordinates where to place the sketch
    /// - Returns: The created annotation
    @discardableResult
    public func addSketchAnnotation(
        pngData: Data,
        bounds: CGRect,
        to page: PDFPage,
        at pagePoint: CGPoint
    ) -> PDFAnnotation? {
        // Create stamp annotation with the sketch image
        let annotationBounds = CGRect(
            x: pagePoint.x,
            y: pagePoint.y,
            width: bounds.width,
            height: bounds.height
        )

        guard let image = UIImage(data: pngData) else {
            sketchLogger.error("Failed to create image from PNG data")
            return nil
        }

        // Create a stamp annotation
        let annotation = PDFAnnotation(
            bounds: annotationBounds,
            forType: .stamp,
            withProperties: nil
        )

        // Set the appearance using the sketch image (using raw key for iOS compatibility)
        annotation.setValue(image, forAnnotationKey: PDFAnnotationKey(rawValue: "/AP"))

        page.addAnnotation(annotation)

        sketchLogger.info("Added sketch annotation at (\(pagePoint.x), \(pagePoint.y))")

        return annotation
    }

    /// Add a sketch annotation at the center of the visible area.
    ///
    /// - Parameters:
    ///   - pngData: The PNG image data of the sketch
    ///   - bounds: The bounds of the sketch in canvas coordinates
    ///   - pdfView: The PDFView to add the annotation to
    /// - Returns: The created annotation
    @discardableResult
    public func addSketchAnnotation(
        pngData: Data,
        bounds: CGRect,
        to pdfView: PDFView
    ) -> PDFAnnotation? {
        guard let currentPage = pdfView.currentPage else {
            sketchLogger.warning("No current page in PDFView")
            return nil
        }

        // Get visible rect in page coordinates
        let visibleRect = pdfView.convert(pdfView.bounds, to: currentPage)

        // Place sketch at center of visible area
        let centerX = visibleRect.midX - bounds.width / 2
        let centerY = visibleRect.midY - bounds.height / 2
        let pagePoint = CGPoint(x: centerX, y: centerY)

        return addSketchAnnotation(
            pngData: pngData,
            bounds: bounds,
            to: currentPage,
            at: pagePoint
        )
    }
}

// MARK: - Preview

#Preview("Sketch Annotation View") {
    IOSSketchAnnotationView(
        drawing: .constant(PKDrawing()),
        pageSize: CGSize(width: 612, height: 792),
        onComplete: { _, _ in },
        onCancel: { }
    )
}

#Preview("Sketch Button") {
    SketchAnnotationButton(
        pageSize: CGSize(width: 612, height: 792)
    ) { data, bounds in
        print("Sketch complete: \(data.count) bytes, bounds: \(bounds)")
    }
    .padding()
}
