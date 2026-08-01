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
///
/// The four appearance knobs below exist for the second adopter, the sidebar's
/// Tags filter, and every one of them defaults to the publication list's
/// behaviour so that call site is unchanged. They are knobs on THIS view rather
/// than a second small filter field because a suite whose whole argument is
/// "same search/filter paradigm everywhere" cannot afford two of them — but the
/// publication filter's syntax help is a lie about a field that matches tag
/// paths, and a field that is always on screen must not steal focus.
public struct FilterInput: View {

    @Binding public var isPresented: Bool
    @Binding public var text: String
    public var matchCount: Int?
    /// The mode-indicator label. "FILTER" for a list; name the SUBJECT when a
    /// surface has more than one filterable thing ("TAGS" in the sidebar).
    public var label: String
    public var placeholder: String
    /// The `?` syntax help. It documents the publication query language, so a
    /// field that filters something else must turn it off rather than offer
    /// help for grammar it does not implement.
    public var showsHelp: Bool
    /// Take keyboard focus on appear. True for a field the user summoned (`/`);
    /// FALSE for one that is simply part of a surface, which would otherwise
    /// grab the keyboard every time that surface is drawn.
    public var autoFocus: Bool
    /// Identifier for the text FIELD itself. `.accessibilityIdentifier` on this
    /// view names the container, and automation needs to address the thing it
    /// types into.
    public var fieldAccessibilityIdentifier: String?
    public var onTextChanged: ((String) -> Void)?
    public var onDismiss: (() -> Void)?
    public var onCancel: (() -> Void)?

    @State private var showHelp = false
    @FocusState private var isFocused: Bool

    public init(
        isPresented: Binding<Bool>,
        text: Binding<String>,
        matchCount: Int? = nil,
        label: String = "FILTER",
        placeholder: String? = nil,
        showsHelp: Bool = true,
        autoFocus: Bool = true,
        fieldAccessibilityIdentifier: String? = nil,
        onTextChanged: ((String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self._text = text
        self.matchCount = matchCount
        self.label = label
        self.placeholder = placeholder
            ?? (showsHelp ? "type to filter... (click ? for help)" : "type to filter...")
        self.showsHelp = showsHelp
        self.autoFocus = autoFocus
        self.fieldAccessibilityIdentifier = fieldAccessibilityIdentifier
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
                ModeIndicator(label, color: .purple)

                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isFocused)
                    .accessibilityIdentifier(fieldAccessibilityIdentifier ?? "filter.field")
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

                if showsHelp {
                    Button {
                        showHelp.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(showHelp ? .purple : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Filter syntax help")
                }

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
            guard autoFocus else { return }
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
