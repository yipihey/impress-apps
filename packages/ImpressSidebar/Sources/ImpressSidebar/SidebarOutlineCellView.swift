//
//  SidebarOutlineCellView.swift
//  ImpressSidebar
//
//  NSTableCellView subclass for SidebarOutlineView rows.
//  Matches GenericTreeRow visual metrics: tree lines, icon, name, count badge.
//

#if os(macOS)
import AppKit

/// Custom cell view for `SidebarOutlineView` rows.
///
/// Renders tree connector lines (└ ├ │), an SF Symbol icon, the node name,
/// and an optional count badge — matching the visual metrics of `GenericTreeRow`.
@MainActor
public final class SidebarOutlineCellView: NSTableCellView {

    // MARK: - Subviews

    private let stackView = NSStackView()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()

    /// Tree line labels for indentation levels.
    private var treeLineLabels: [NSTextField] = []

    // MARK: - State

    private var isConfigured = false

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    // MARK: - Setup

    private func setupViews() {
        guard !isConfigured else { return }
        isConfigured = true

        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Icon: 12pt system font, 16pt frame, 2pt leading padding
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Name: single line, truncation
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Badge: pill shape
        badgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        badgeLabel.alignment = .center
        badgeLabel.isBordered = false
        badgeLabel.isEditable = false
        badgeLabel.drawsBackground = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)

        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerRadius = 7
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -5),
            badgeLabel.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -1),
        ])

        self.textField = nameField
        self.imageView = iconView
    }

    // MARK: - Configuration

    /// Configure the cell for a given node.
    ///
    /// - Parameters:
    ///   - displayName: The node's display name
    ///   - iconName: SF Symbol name for the icon
    ///   - iconColor: Color for the icon (nil = secondary label color)
    ///   - displayCount: Optional badge count
    ///   - treeDepth: Depth in the tree hierarchy (0 = root)
    ///   - isLastChild: Whether this node is the last child of its parent
    ///   - ancestorHasSiblingsBelow: For each ancestor level, whether that ancestor has more siblings
    ///   - isExpandable: Whether this node has children
    public func configure(
        displayName: String,
        iconName: String,
        iconColor: NSColor?,
        displayCount: Int?,
        treeDepth: Int,
        isLastChild: Bool,
        ancestorHasSiblingsBelow: [Bool],
        isExpandable: Bool
    ) {
        // Rebuild stack view contents
        // Remove previous arranged subviews
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // Tree lines for indentation
        configureTreeLines(
            depth: treeDepth,
            isLastChild: isLastChild,
            ancestorHasSiblingsBelow: ancestorHasSiblingsBelow
        )

        // Spacer for disclosure triangle alignment (NSOutlineView provides its own)
        // No explicit spacer needed — NSOutlineView handles indentation

        // Icon with 6pt leading padding (space after NSOutlineView's disclosure triangle)
        let iconSpacer = NSView()
        iconSpacer.translatesAutoresizingMaskIntoConstraints = false
        iconSpacer.widthAnchor.constraint(equalToConstant: 6).isActive = true
        stackView.addArrangedSubview(iconSpacer)

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = iconColor ?? .secondaryLabelColor
        stackView.addArrangedSubview(iconView)

        // Name with 4pt leading padding
        let nameSpacer = NSView()
        nameSpacer.translatesAutoresizingMaskIntoConstraints = false
        nameSpacer.widthAnchor.constraint(equalToConstant: 4).isActive = true
        stackView.addArrangedSubview(nameSpacer)

        nameField.stringValue = displayName
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize)
        stackView.addArrangedSubview(nameField)

        // Badge
        if let count = displayCount, count > 0 {
            let badgeSpacer = NSView()
            badgeSpacer.translatesAutoresizingMaskIntoConstraints = false
            badgeSpacer.widthAnchor.constraint(equalToConstant: 4).isActive = true
            stackView.addArrangedSubview(badgeSpacer)

            badgeLabel.stringValue = "\(count)"
            badgeLabel.textColor = .secondaryLabelColor
            badgeContainer.layer?.backgroundColor = NSColor.secondaryLabelColor
                .withAlphaComponent(0.2).cgColor
            badgeContainer.isHidden = false
            stackView.addArrangedSubview(badgeContainer)
        } else {
            badgeContainer.isHidden = true
        }
    }

    // MARK: - Tree Lines

    private func configureTreeLines(
        depth: Int,
        isLastChild: Bool,
        ancestorHasSiblingsBelow: [Bool]
    ) {
        // Remove old tree line labels
        for label in treeLineLabels {
            stackView.removeArrangedSubview(label)
            label.removeFromSuperview()
        }
        treeLineLabels.removeAll()

        guard depth > 0 else { return }

        for level in 0..<depth {
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .quaternaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 12).isActive = true

            if level == depth - 1 {
                // Final level: └ or ├
                label.stringValue = isLastChild ? "\u{2514}" : "\u{251C}" // └ or ├
            } else {
                // Parent levels: │ if ancestor has siblings below, else space
                let hasSiblingsBelow = level < ancestorHasSiblingsBelow.count
                    ? ancestorHasSiblingsBelow[level]
                    : false
                label.stringValue = hasSiblingsBelow ? "\u{2502}" : " " // │ or space
            }

            treeLineLabels.append(label)
            stackView.addArrangedSubview(label)
        }
    }

    // MARK: - Inline Editing

    /// Begin inline editing of the name field.
    /// - Parameter delegate: The NSTextFieldDelegate to handle editing end events.
    public func beginEditing(delegate: NSTextFieldDelegate? = nil) {
        nameField.delegate = delegate
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.becomeFirstResponder()
        // Select all text
        if let editor = nameField.currentEditor() {
            editor.selectAll(nil)
        }
    }

    /// End inline editing and return the current name.
    @discardableResult
    public func endEditing() -> String {
        let name = nameField.stringValue
        nameField.isEditable = false
        nameField.isSelectable = false
        return name
    }

    // MARK: - Reuse

    public override func prepareForReuse() {
        super.prepareForReuse()
        nameField.isEditable = false
        nameField.isSelectable = false
        badgeContainer.isHidden = true
        for label in treeLineLabels {
            stackView.removeArrangedSubview(label)
            label.removeFromSuperview()
        }
        treeLineLabels.removeAll()
    }
}
#endif
