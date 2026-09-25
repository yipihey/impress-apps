//
//  GoToPageSheet.swift
//  PublicationManagerCore
//
//  Go ▸ Go to Page… (⌘G): the page prompt.
//

import SwiftUI

/// What the user typed into Go to Page, as a page of a `totalPages`-page
/// document. Out-of-range numbers clamp (as PDFKit's own "go to page" does);
/// anything that is not a whole number is `nil`.
public enum GoToPageInput {
    public static func page(from text: String, totalPages: Int) -> Int? {
        guard totalPages > 0,
              let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return min(max(1, n), totalPages)
    }
}

#if os(macOS)
/// A one-field sheet: type a page number, Return goes, Escape cancels.
struct GoToPageSheet: View {
    let currentPage: Int
    let totalPages: Int
    let onGo: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    private var target: Int? { GoToPageInput.page(from: text, totalPages: totalPages) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Page").font(.headline)
            HStack {
                TextField("Page", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($fieldFocused)
                    .onSubmit(go)
                Text("of \(totalPages)").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil)
            }
        }
        .padding(20)
        .frame(width: 260)
        .onAppear {
            text = String(currentPage)
            fieldFocused = true
        }
    }

    private func go() {
        guard let target else { return }
        onGo(target)
        dismiss()
    }
}
#endif

#if os(macOS)
/// The PDF view's `.pdfGoToPage` observer. A `page` (1-based) in the
/// userInfo navigates — the Notes tab's reMarkable rows and
/// `imbib://pdf?action=go-to-page` post one — scoped to this document when
/// a `linkedFileID` is given. Go ▸ Go to Page… (⌘G) posts no page, and until
/// 2026-09-25 that post did nothing; now the viewer the user is looking at
/// (the key window's, not every mounted one) asks for a page.
struct GoToPageCommand: ViewModifier {
    let linkedFileID: UUID?
    let totalPages: Int
    @Binding var currentPage: Int
    let isInKeyWindow: () -> Bool

    @State private var showPrompt = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .pdfGoToPage)) { notification in
                guard AnnotationCommandTarget.applies(notification, displayed: linkedFileID),
                      totalPages > 0
                else { return }
                if let page = notification.userInfo?["page"] as? Int {
                    currentPage = min(max(1, page), totalPages)
                    return
                }
                guard isInKeyWindow() else { return }
                logInfo("Go ▸ Go to Page: asking (page \(currentPage) of \(totalPages))", category: "pdf")
                showPrompt = true
            }
            .sheet(isPresented: $showPrompt) {
                GoToPageSheet(currentPage: currentPage, totalPages: totalPages) { page in
                    logInfo("Go ▸ Go to Page: \(page) of \(totalPages)", category: "pdf")
                    currentPage = page
                }
            }
    }
}
#endif
