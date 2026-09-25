//
//  MenuNotificationObserverTests.swift
//  PublicationManagerCoreTests
//
//  Every notification an imbib menu command posts must have an observer.
//
//  A menu item that posts a name nobody observes looks finished — it has a
//  title, a chord, a row in Settings ▸ Keyboard and the ⌘/ window — and does
//  nothing. PR #61 found Paper ▸ Save to Library had been that since cdca0b23;
//  the audit that followed (2026-09-24) found seventeen more, among them
//  Dismiss from Inbox, Move/Add/Remove Collection, Copy DOI/URL, Open
//  References, Refresh, and ⌘1 / ⌘3 (observed only by the iOS root since
//  b748151d deleted the macOS handlers). This test is the scan that would
//  have caught every one of them.
//
//  What it reads: the posts inside `AppCommands` in imbibApp.swift (SwiftUI
//  cannot enumerate a built `Commands` body), plus `ImbibSearchAction.post()`,
//  which posts `.performSearchAction`. The chassis commands imbib mounts —
//  `ImpressAboutCommand`, `ImpressPaneLayoutButtons` — post nothing (checked
//  below). An observer is any `publisher(for:)`, `addObserver(… name:)`,
//  `addObserver(forName:)`, `notifications(named:)` or `.onNotifications`
//  tuple for the name, anywhere the macOS app links: apps/imbib (not the iOS
//  target, not tests) and packages/.
//

import XCTest

final class MenuNotificationObserverTests: XCTestCase {

    /// Names a menu command posts FOR SOMETHING OUTSIDE THIS APP to observe.
    /// None today: every menu post is meant for imbib's own views.
    static let external: Set<String> = []

    /// Menu commands that still post a name nothing observes, because the
    /// action they name does not exist yet or needs a product decision. Each
    /// entry is a known dead menu item, not an exemption: when one is wired,
    /// this test fails until it leaves the list.
    ///
    /// Empty since 2026-09-25: the nine listed here after #62 (⌘2, ⌘[ / ⌘],
    /// ⇧⌘C, ⌥⌘1 / ⌥⌘3, ⇧⌘F, ⇧⌘\, ⇧⌘?) are wired and pinned by name below.
    static let unwired: [String: String] = [:]

    func testEveryMenuNotificationHasAnObserver() throws {
        let posted = try Self.menuPostedNames()
        XCTAssertGreaterThan(posted.count, 40, "the scan stopped matching imbibApp.swift's posts")
        let corpus = try Self.observerCorpus()

        var unobserved: Set<String> = []
        for name in posted where !Self.external.contains(name) {
            if !Self.isObserved(name, in: corpus) { unobserved.insert(name) }
        }

        let newlyDead = unobserved.subtracting(Self.unwired.keys).sorted()
        XCTAssertEqual(
            newlyDead, [],
            "these menu commands post a notification nothing in the macOS app observes: \(newlyDead)")

        let nowWired = Set(Self.unwired.keys).subtracting(unobserved).sorted()
        XCTAssertEqual(
            nowWired, [],
            "these are observed now — take them out of `unwired`: \(nowWired)")
    }

    /// The fixed ones stay fixed, by name (and the scan can see an observer
    /// of each form it claims to).
    func testTheCommandsFixedOn20260924AreObserved() throws {
        let corpus = try Self.observerCorpus()
        for name in [
            "saveToLibrary", "dismissFromInbox", "moveToCollection", "addToCollection",
            "removeFromCollection", "showLibrary", "showInbox", "copyIdentifier",
            "openReferences", "refreshData", "focusList", "addNoteAtSelection",
            // `addObserver(self, selector:, name: .x, …)` form:
            "highlightSelection", "flipWindowPositions",
        ] {
            XCTAssertTrue(Self.isObserved(name, in: corpus), "\(name) has no observer")
        }
    }

    /// The nine that were `unwired` until 2026-09-25 stay wired.
    func testTheCommandsFixedOn20260925AreObserved() throws {
        let corpus = try Self.observerCorpus()
        for name in [
            "showSearch", "navigateBack", "navigateForward", "copyAsCitation",
            "focusSidebar", "focusDetail", "sharePapers", "togglePDFFilter",
            "showHelpSearchPalette",
        ] {
            XCTAssertTrue(Self.isObserved(name, in: corpus), "\(name) has no observer")
        }
        XCTAssertTrue(Self.unwired.isEmpty, "a menu command is known dead again: \(Self.unwired.keys.sorted())")
    }

    /// The chassis commands imbib mounts post no notifications — if one
    /// starts to, this scan must read it too.
    func testTheMountedChassisCommandsPostNothing() throws {
        for path in [
            "packages/ImpressKit/Sources/ImpressKit/ImpressBuildInfo.swift",
            "apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Chassis/Shared/PaneLayoutCommands.swift",
        ] {
            XCTAssertFalse(
                try Self.source(of: path).contains("NotificationCenter.default.post"),
                "\(path) posts a notification; add it to the menu scan")
        }
    }

    // MARK: - Scan

    /// Every `.post(name: .x` inside `struct AppCommands`, plus
    /// `.performSearchAction` for `ImbibSearchAction(...).post()`.
    static func menuPostedNames() throws -> Set<String> {
        let source = try source(of: "apps/imbib/imbib/imbib/imbibApp.swift")
        guard let start = source.range(of: "struct AppCommands: Commands") else {
            XCTFail("imbibApp.swift no longer declares AppCommands")
            return []
        }
        let commands = String(source[start.lowerBound...])
        var names = Set(matches(#"\.post\(\s*name:\s*\.([A-Za-z0-9_]+)"#, in: commands))
        if commands.contains("ImbibSearchAction.") && commands.contains(".post()") {
            names.insert("performSearchAction")
        }
        return names
    }

    static func isObserved(_ name: String, in corpus: String) -> Bool {
        let n = NSRegularExpression.escapedPattern(for: name)
        let forms = [
            #"publisher\(\s*for:\s*\.\#(n)\b"#,
            #"forName:\s*\.\#(n)\b"#,
            #"notifications\(\s*named:\s*\.\#(n)\b"#,
            #"\(\s*\.\#(n)\s*,\s*\{"#,
            // addObserver(self, selector: #selector(f), name: .x, object: …)
            // (one level of nested parentheses, so it cannot run on into
            // the next call).
            #"addObserver\((?:[^(){}]|\((?:[^()]|\([^()]*\))*\))*?name:\s*\.\#(n)\b"#,
        ]
        return forms.contains { !matches($0, in: corpus, options: [.dotMatchesLineSeparators]).isEmpty }
    }

    /// Every Swift source the macOS app links, concatenated.
    static func observerCorpus() throws -> String {
        var text = ""
        let fm = FileManager.default
        for base in ["apps/imbib", "packages"] {
            let root = repoRoot.appendingPathComponent(base)
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker {
                let path = url.path
                if path.contains("/.build") || path.contains("/DerivedData") {
                    walker.skipDescendants(); continue
                }
                guard url.pathExtension == "swift",
                      !path.contains("/Tests/"), !path.contains("UITests/"),
                      !path.contains("/imbib-iOS/")
                else { continue }
                text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                text += "\n"
            }
        }
        XCTAssertGreaterThan(text.count, 1_000_000, "the observer corpus is suspiciously small")
        return text
    }

    private static func matches(
        _ pattern: String, in text: String, options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound
                ? ns.substring(with: $0.range(at: 1)) : ns.substring(with: $0.range)
        }
    }

    /// …/apps/imbib/PublicationManagerCore/Tests/PublicationManagerCoreTests/<this>:
    /// six components up is the repository root.
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    func testTheScanFindsTheRepositoryRoot() throws {
        XCTAssertTrue(try Self.source(of: "docs/keyboard-grammar.md").contains("⌃⌘S"))
    }

    static func source(of relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
