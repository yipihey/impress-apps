//
//  ShareProvider.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Shareable Item

/// Items that can be shared via the platform share sheet.
public enum ShareableItem: Sendable {
    case text(String)
    case url(URL)
    case file(URL)
    case data(Data, filename: String)
}

// MARK: - Share Sheet Modifier

/// A view modifier that presents a share sheet for the given items.
///
/// Usage:
/// ```swift
/// Button("Share") { showShare = true }
///     .shareSheet(isPresented: $showShare, items: [.text(bibtex)])
/// ```
public struct ShareSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let items: [ShareableItem]

    public func body(content: Content) -> some View {
        content
            #if os(macOS)
            .background(
                ShareSheetPresenter(isPresented: $isPresented, items: items)
            )
            #else
            .sheet(isPresented: $isPresented) {
                ActivityViewController(items: items)
            }
            #endif
    }
}

extension View {
    /// Present a platform-appropriate share sheet.
    public func shareSheet(isPresented: Binding<Bool>, items: [ShareableItem]) -> some View {
        modifier(ShareSheetModifier(isPresented: isPresented, items: items))
    }
}

// MARK: - Platform-Specific Implementation

#if os(macOS)

/// macOS share sheet presenter using NSSharingServicePicker.
private struct ShareSheetPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let items: [ShareableItem]

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isPresented {
            DispatchQueue.main.async {
                let shareItems = items.map { item -> Any in
                    switch item {
                    case .text(let string):
                        return string
                    case .url(let url):
                        return url
                    case .file(let url):
                        return url
                    case .data(let data, let filename):
                        // Write to temp file for sharing
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                        try? data.write(to: tempURL)
                        return tempURL
                    }
                }

                let picker = NSSharingServicePicker(items: shareItems)
                picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
                isPresented = false
            }
        }
    }
}

#else

/// iOS share sheet using UIActivityViewController.
private struct ActivityViewController: UIViewControllerRepresentable {
    let items: [ShareableItem]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let activityItems = items.map { item -> Any in
            switch item {
            case .text(let string):
                return string
            case .url(let url):
                return url
            case .file(let url):
                return url
            case .data(let data, let filename):
                // Write to temp file for sharing
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try? data.write(to: tempURL)
                return tempURL
            }
        }

        return UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#endif
