//
//  FilterInput.swift
//  ImpressFTUI
//

import SwiftUI

/// Inline text field for entering filter expressions with keyboard.
///
/// The caller owns the text via a `Binding<String>`. Every keystroke is
/// reflected immediately in both directions — external updates (e.g. tag
/// clicks appending tokens) appear in the field without recreating the view.
///
/// - Enter: dismiss the input (filter stays active)
/// - ESC: clear filter and dismiss
/// - ?: toggle syntax help
public struct FilterInput: View {

    @Binding public var isPresented: Bool
    @Binding public var text: String
    public var matchCount: Int?
    public var onTextChanged: ((String) -> Void)?
    public var onDismiss: (() -> Void)?
    public var onCancel: (() -> Void)?

    @State private var showHelp = false
    @FocusState private var isFocused: Bool

    public init(
        isPresented: Binding<Bool>,
        text: Binding<String>,
        matchCount: Int? = nil,
        onTextChanged: ((String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self._text = text
        self.matchCount = matchCount
        self.onTextChanged = onTextChanged
        self.onDismiss = onDismiss
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showHelp {
                filterHelpView
            }

            HStack(spacing: 6) {
                ModeIndicator("FILTER", color: .purple)

                TextField("type to filter... (click ? for help)", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isFocused)
                    .onSubmit {
                        // Enter: keep filter active, just dismiss the input
                        isPresented = false
                        onDismiss?()
                    }
                    .onKeyPress(.escape) {
                        if showHelp {
                            showHelp = false
                            return .handled
                        }
                        // ESC: clear filter and dismiss
                        text = ""
                        onTextChanged?("")
                        isPresented = false
                        onCancel?()
                        return .handled
                    }
                    .onChange(of: text) { _, newValue in
                        onTextChanged?(newValue)
                    }

                if let count = matchCount, !text.isEmpty {
                    Text("\(count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }

                Button {
                    showHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(showHelp ? .purple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Filter syntax help")

                if !text.isEmpty {
                    Button {
                        text = ""
                        onTextChanged?("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            isFocused = true
        }
    }

    private var filterHelpView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Filter Syntax")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.purple)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                helpRow("word", "Search all fields")
                helpRow("\"exact phrase\"", "Match exact phrase")
                helpRow("-word", "Exclude matches")
                helpRow("title:word  (ti:)", "Search title only")
                helpRow("author:name (au:)", "Search authors only")
                helpRow("abstract:term (ab:)", "Search abstract only")
                helpRow("venue:name  (ve:)", "Search venue only")
                helpRow("year:2024   (y:)", "Exact year")
                helpRow("year:2020-2024", "Year range")
                helpRow("year:>2020", "After year (also <, >=, <=)")
                helpRow("flag:red    (f:)", "Has flag color")
                helpRow("flag:*  -flag:*", "Any flag / no flag")
                helpRow("tags:path   (t:)", "Has tag prefix")
                helpRow("tags:a+b", "Multiple tags (AND)")
                helpRow("-tags:path", "Exclude tag")
                helpRow("read  unread", "Read state")
            }

            HStack(spacing: 4) {
                Text("Enter")
                    .fontWeight(.medium)
                Text("keep filter")
                Text("·")
                Text("Esc")
                    .fontWeight(.medium)
                Text("clear & close")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    @ViewBuilder private func helpRow(_ syntax: String, _ desc: String) -> some View {
        GridRow {
            Text(syntax)
                .foregroundStyle(.primary)
            Text(desc)
                .foregroundStyle(.secondary)
        }
    }
}
