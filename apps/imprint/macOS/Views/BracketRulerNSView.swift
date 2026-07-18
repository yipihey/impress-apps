import AppKit
import ImpressLogging
import OSLog

/// A Mathematica-notebook–style "cell bracket" column drawn in the editor's
/// right margin. Each structural element (section, paragraph) gets a nested
/// bracket aligned to its vertical extent. Left-click selects the element's
/// source range; right-click offers Copy / Cut / Delete (the future entry
/// point for AI interactions).
///
/// Added as a subview of the `NSTextView` so it scrolls with the document; the
/// text container is inset on the right to make room (see `SourceEditorView`).
final class BracketRulerNSView: NSView {

    /// Total width of the bracket gutter.
    static let gutterWidth: CGFloat = 44
    /// Space kept clear at the right for the scroll bar, so the brackets sit to
    /// its left and stay clickable (the overlay scroller would otherwise cover
    /// and intercept clicks on brackets drawn at the very edge).
    private static let scrollerReserve: CGFloat = 16
    /// Preferred horizontal indent per nesting level (deeper = further left);
    /// compressed automatically when a document nests deeper than the gutter fits.
    private static let indentPerLevel: CGFloat = 7
    /// Length of the little horizontal ticks at a bracket's top/bottom.
    private static let tickLength: CGFloat = 5

    weak var textView: NSTextView?
    private var nodes: [StructureNode] = []
    /// Deepest nesting level present, used to compress indentation to fit.
    private var maxLevel: Int = 0

    /// Curated AI author-tasks shown in the bracket's "AI" submenu, as
    /// (actionId, title, SF Symbol). Set by the editor coordinator so the ruler
    /// (AppKit) needn't reach into the @MainActor task service.
    var aiTasks: [(id: String, title: String, icon: String)] = []
    /// Invoked when the user picks an AI task on a bracket, with the task's
    /// action id and the node's source range.
    var aiRequestHandler: ((_ actionId: String, _ range: NSRange) -> Void)?
    /// Cached per-node geometry (in this view's flipped coords), recomputed on
    /// draw and reused for hit-testing: vertical extent + spine x.
    private var nodeFrames: [(node: StructureNode, top: CGFloat, bottom: CGFloat, x: CGFloat)] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false } // never steal keyboard focus

    func update(nodes: [StructureNode]) {
        self.nodes = nodes
        self.maxLevel = nodes.map { $0.level }.max() ?? 0
        needsDisplay = true
    }

    // MARK: - Geometry

    /// The x of the outermost (level 0) spine — left of the reserved scroll strip.
    private var rightEdge: CGFloat { bounds.maxX - Self.scrollerReserve }

    /// Horizontal step between nesting levels, compressed so even the deepest
    /// level keeps its spine (and left-pointing tick) inside the gutter.
    private var levelStep: CGFloat {
        guard maxLevel > 0 else { return Self.indentPerLevel }
        let usable = rightEdge - (Self.tickLength + 2) // keep the deepest tick visible
        return min(Self.indentPerLevel, max(3, usable / CGFloat(maxLevel)))
    }

    private func spineX(for level: Int) -> CGFloat {
        rightEdge - CGFloat(level) * levelStep
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        nodeFrames.removeAll(keepingCapacity: true)

        for node in nodes {
            // Vertical extent of the node's source range in text-view coords.
            let glyphRange = lm.glyphRange(forCharacterRange: node.range, actualCharacterRange: nil)
            guard glyphRange.length > 0 || node.range.length == 0 else { continue }
            let bounding = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let top = bounding.minY + origin.y
            let bottom = bounding.maxY + origin.y
            guard bottom > top else { continue }

            let x = spineX(for: node.level)
            nodeFrames.append((node, top, bottom, x))

            let path = NSBezierPath()
            // Outer (shallower) brackets read as heavier; paragraphs are the
            // faintest. Section weight tapers with depth so the hierarchy is
            // legible at a glance.
            let isSection = node.kind == .section
            path.lineWidth = isSection ? max(1.0, 1.7 - 0.25 * CGFloat(node.level)) : 0.9
            // Vertical spine
            path.move(to: CGPoint(x: x, y: top + 1))
            path.line(to: CGPoint(x: x, y: bottom - 1))
            // Top + bottom ticks pointing left (into the text)
            path.move(to: CGPoint(x: x, y: top + 1))
            path.line(to: CGPoint(x: x - Self.tickLength, y: top + 1))
            path.move(to: CGPoint(x: x, y: bottom - 1))
            path.line(to: CGPoint(x: x - Self.tickLength, y: bottom - 1))
            (isSection ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
            path.stroke()
        }
    }

    // MARK: - Hit-testing

    /// The node the click targets: among all brackets spanning the click's
    /// vertical position, the one whose spine is horizontally nearest — so
    /// clicking near the outer spine picks the section, near the inner spine a
    /// paragraph. Clicking anywhere in the gutter row selects *something*.
    private func node(at point: CGPoint) -> StructureNode? {
        let spanning = nodeFrames.filter { point.y >= $0.top - 3 && point.y <= $0.bottom + 3 }
        guard !spanning.isEmpty else { return nil }
        return spanning.min(by: { abs($0.x - point.x) < abs($1.x - point.x) })?.node
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let node = node(at: p), let textView else {
            super.mouseDown(with: event)
            return
        }
        textView.setSelectedRange(node.range)
        textView.scrollRangeToVisible(node.range)
        textView.window?.makeFirstResponder(textView)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let node = node(at: p) else { return nil }
        // Select the target so the actions + visual feedback are unambiguous.
        textView?.setSelectedRange(node.range)

        let menu = NSMenu()
        // Our curated menu only — suppress the system's auto-injected plug-ins
        // (raw Services/AutoFill). We offer Writing Tools ourselves below, bound
        // to this element's range so it never runs against the whole document.
        menu.allowsContextMenuPlugIns = false
        let label = node.kind == .section ? "Section" : "Paragraph"
        menu.addItem(withTitle: "Copy \(label)", action: #selector(copyNode(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Cut \(label)", action: #selector(cutNode(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Delete \(label)", action: #selector(deleteNode(_:)), keyEquivalent: "")
        // Writing Tools (Apple Intelligence) on exactly this element — the first
        // of the bracket's AI entry points.
        if #available(macOS 15.2, *) {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rewrite with Writing Tools…",
                         action: #selector(writingToolsNode(_:)), keyEquivalent: "")
        }
        for item in menu.items { item.target = self; item.representedObject = NSValue(range: node.range) }

        // Configurable AI author-tasks on exactly this element. Built from the
        // curated list the coordinator supplies; each carries its own payload
        // (added AFTER the loop above so subitems keep their action id + range).
        if !aiTasks.isEmpty {
            menu.addItem(.separator())
            let aiItem = NSMenuItem(title: "AI", action: nil, keyEquivalent: "")
            aiItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            let submenu = NSMenu()
            submenu.allowsContextMenuPlugIns = false
            for task in aiTasks {
                let item = submenu.addItem(withTitle: task.title, action: #selector(runAITask(_:)), keyEquivalent: "")
                item.target = self
                item.image = NSImage(systemSymbolName: task.icon, accessibilityDescription: nil)
                item.representedObject = BracketAIMenuPayload(actionId: task.id, range: node.range)
            }
            aiItem.submenu = submenu
            menu.addItem(aiItem)
        }
        return menu
    }

    @objc private func runAITask(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? BracketAIMenuPayload else { return }
        aiRequestHandler?(payload.actionId, payload.range)
    }

    // MARK: - Actions (undo-safe via the text view's editing pipeline)

    @objc private func copyNode(_ sender: NSMenuItem) {
        guard let r = (sender.representedObject as? NSValue)?.rangeValue, let tv = textView else { return }
        let text = (tv.string as NSString).substring(with: r)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func cutNode(_ sender: NSMenuItem) {
        copyNode(sender)
        deleteNode(sender)
    }

    /// Select this element's range and hand it to Apple's Writing Tools. Driving
    /// it from a bounded selection (one paragraph/section) keeps it responsive —
    /// invoking Writing Tools with no selection processes the whole markup
    /// document, which stalls then fails.
    @available(macOS 15.2, *)
    @objc private func writingToolsNode(_ sender: NSMenuItem) {
        guard let r = (sender.representedObject as? NSValue)?.rangeValue, let tv = textView else { return }
        tv.setSelectedRange(r)
        tv.window?.makeFirstResponder(tv)
        tv.showWritingTools(sender)
    }

    @objc private func deleteNode(_ sender: NSMenuItem) {
        guard let r = (sender.representedObject as? NSValue)?.rangeValue, let tv = textView else { return }
        // Go through the text view so undo + the delegate's textDidChange (which
        // updates the SwiftUI source binding + re-highlights) both fire.
        if tv.shouldChangeText(in: r, replacementString: "") {
            tv.textStorage?.replaceCharacters(in: r, with: "")
            tv.didChangeText()
        }
    }
}

/// Menu payload carrying an AI action id together with the target source range,
/// so a bracket's "AI ▸ <task>" item knows both what to run and where.
private final class BracketAIMenuPayload: NSObject {
    let actionId: String
    let range: NSRange
    init(actionId: String, range: NSRange) {
        self.actionId = actionId
        self.range = range
    }
}
