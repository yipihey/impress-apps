//
//  KeyboardShortcutCatalogParityTests.swift
//  PublicationManagerCoreTests
//
//  Locks `KeyboardShortcutsSettings.defaults` to a byte-exact snapshot taken
//  BEFORE the ~600-line literal binding table was moved into ImpressKeyboard's
//  shared `ShortcutCatalog`. The settings UI renders
//  `ShortcutCategory.allCases` × `bindings(for:)`, so category order,
//  within-category order, display name and display shortcut fully determine
//  what the user sees — all of which this snapshot pins, plus the id /
//  notification name / customizability that `mergeWithDefaults` depends on.
//
//  If this test fails, the resolved list changed. That is either a bug in the
//  shared-catalog resolution or a deliberate vocabulary change; either way it
//  is never invisible again.
//

import XCTest
@testable import PublicationManagerCore

final class KeyboardShortcutCatalogParityTests: XCTestCase {

    /// One canonical line per binding, in resolution order.
    private func snapshot(_ settings: KeyboardShortcutsSettings) -> String {
        settings.bindings.map { b in
            [
                b.id,
                b.displayName,
                b.category.rawValue,
                b.key.stringValue,
                String(b.modifiers.rawValue),
                b.notificationName,
                b.isCustomizable ? "1" : "0",
                b.displayShortcut,
            ].joined(separator: "|")
        }.joined(separator: "\n")
    }

    func testDefaultsMatchPreMoveSnapshot() {
        let actual = snapshot(KeyboardShortcutsSettings.defaults)
        if actual != Self.preMoveSnapshot {
            // Printed so the diff is actionable, not just "not equal".
            print("=== ACTUAL SNAPSHOT BEGIN ===")
            print(actual)
            print("=== ACTUAL SNAPSHOT END ===")
        }
        XCTAssertEqual(
            actual,
            Self.preMoveSnapshot,
            "KeyboardShortcutsSettings.defaults no longer reproduces the pre-move settings list."
        )
    }

    /// The settings UI's exact render order: categories in `allCases` order,
    /// bindings in table order within each category.
    func testRenderedOrderIsUnchanged() {
        let settings = KeyboardShortcutsSettings.defaults
        var rendered: [String] = []
        for category in ShortcutCategory.allCases {
            for binding in settings.bindings(for: category) {
                rendered.append("\(category.rawValue)/\(binding.id)/\(binding.displayShortcut)")
            }
        }
        XCTAssertEqual(rendered.joined(separator: "\n"), Self.preMoveRenderedOrder)
        // Every binding lands in exactly one rendered category.
        XCTAssertEqual(rendered.count, settings.bindings.count)
    }

    /// The pre-existing conflict set is unchanged — the move must not silently
    /// add or resolve a key collision.
    func testConflictSetIsUnchanged() {
        let conflicts = KeyboardShortcutsSettings.defaults.detectConflicts()
            .map { "\($0.0.id)+\($0.1.id)" }
            .sorted()
        XCTAssertEqual(conflicts.joined(separator: ","), Self.preMoveConflicts)
    }

    // MARK: - Fixtures (captured from the literal table before the move)

    static let preMoveSnapshot = #"""
navigateDown|Down (Vim)|Navigation|j|0|navigateNextPaper|1|j
navigateUp|Up (Vim)|Navigation|k|0|navigatePreviousPaper|1|k
cycleFocusLeft|Focus Left Pane|Navigation|h|0|cycleFocusLeft|1|h
cycleFocusRight|Focus Right Pane|Navigation|l|0|cycleFocusRight|1|l
showInfoTabVim|Info Tab|Navigation|i|0|showInfoTab|1|i
showPDFTabVim|PDF Tab|Navigation|p|0|showPDFTab|1|p
showNotesTabVim|Notes Tab|Navigation|n|0|showNotesTab|1|n
showBibTeXTabVim|BibTeX Tab|Navigation|b|0|showBibTeXTab|1|b
navigateNextPaper|Next Paper|Navigation|downArrow|0|navigateNextPaper|1|↓
navigatePreviousPaper|Previous Paper|Navigation|upArrow|0|navigatePreviousPaper|1|↑
navigateFirstPaper|First Paper|Navigation|upArrow|1|navigateFirstPaper|1|⌘↑
navigateLastPaper|Last Paper|Navigation|downArrow|1|navigateLastPaper|1|⌘↓
navigateNextUnread|Next Unread|Navigation|downArrow|4|navigateNextUnread|1|⌥↓
navigatePreviousUnread|Previous Unread|Navigation|upArrow|4|navigatePreviousUnread|1|⌥↑
navigateNextUnreadVim|Next Unread (Vim)|Navigation|j|4|navigateNextUnread|1|⌥j
navigatePreviousUnreadVim|Previous Unread (Vim)|Navigation|k|4|navigatePreviousUnread|1|⌥k
openSelectedPaper|Open Paper|Navigation|return|0|openSelectedPaper|1|↩
showLibrary|Show Library|Views|1|1|showLibrary|1|⌘1
showSearch|Show Search|Views|2|1|showSearch|1|⌘2
showInbox|Show Inbox|Views|3|1|showInbox|1|⌘3
showPDFTab|Show PDF Tab|Views|4|1|showPDFTab|1|⌘4
showBibTeXTab|Show BibTeX Tab|Views|5|1|showBibTeXTab|1|⌘5
showNotesTab|Show Notes Tab|Views|6|1|showNotesTab|1|⌘6
toggleDetailPane|Toggle Detail Pane|Views|0|1|toggleDetailPane|1|⌘0
toggleSidebar|Toggle Sidebar|Views|s|9|toggleSidebar|1|⌃⌘s
focusSidebar|Focus Sidebar|Focus|1|5|focusSidebar|1|⌥⌘1
focusList|Focus List|Focus|2|5|focusList|1|⌥⌘2
focusDetail|Focus Detail|Focus|3|5|focusDetail|1|⌥⌘3
focusSearch|Focus Search Field|Focus|f|1|focusSearch|1|⌘f
showNotesTabR|Open Notes|Paper Actions|r|1|showNotesTab|1|⌘r
openReferences|Open References|Paper Actions|r|3|openReferences|1|⇧⌘r
toggleReadStatus|Toggle Read/Unread|Paper Actions|u|3|toggleReadStatus|1|⇧⌘u
markAllAsRead|Mark All as Read|Paper Actions|u|5|markAllAsRead|1|⌥⌘u
saveToLibrary|Save to Library|Paper Actions|s|9|saveToLibrary|1|⌃⌘s
dismissFromInbox|Dismiss from Inbox|Paper Actions|j|3|dismissFromInbox|1|⇧⌘j
addToCollection|Add to Collection|Paper Actions|l|1|addToCollection|1|⌘l
removeFromCollection|Remove from Collection|Paper Actions|l|3|removeFromCollection|1|⇧⌘l
moveToCollection|Move to Collection|Paper Actions|m|9|moveToCollection|1|⌃⌘m
sharePapers|Share|Paper Actions|f|3|sharePapers|1|⇧⌘f
deleteSelectedPapers|Delete|Paper Actions|delete|1|deleteSelectedPapers|1|⌘⌫
copyPublications|Copy BibTeX|Clipboard|c|1|copyPublications|1|⌘c
copyAsCitation|Copy as Citation|Clipboard|c|3|copyAsCitation|1|⇧⌘c
copyIdentifier|Copy DOI/URL|Clipboard|c|5|copyIdentifier|1|⌥⌘c
cutPublications|Cut|Clipboard|x|1|cutPublications|1|⌘x
pastePublications|Paste|Clipboard|v|1|pastePublications|1|⌘v
selectAllPublications|Select All|Clipboard|a|1|selectAllPublications|1|⌘a
toggleUnreadFilter|Toggle Unread Filter|Filtering|\|1|toggleUnreadFilter|1|⌘\
togglePDFFilter|Toggle PDF Filter|Filtering|\|3|togglePDFFilter|1|⇧⌘\
inboxSave|Save|Inbox Triage|*|0|inboxSave|1|*
inboxSaveAndStar|Save and Star|Inbox Triage|s|2|inboxSaveAndStar|1|Shift+s
inboxToggleStar|Toggle Star|Inbox Triage|s|0|inboxToggleStar|1|s
inboxDismiss|Dismiss|Inbox Triage|d|0|inboxDismiss|1|d
inboxMarkRead|Mark as Read|Inbox Triage|r|0|inboxMarkRead|1|r
inboxMarkUnread|Mark as Unread|Inbox Triage|u|0|inboxMarkUnread|1|u
inboxNextItem|Next (Vim)|Inbox Triage|j|0|inboxNextItem|1|j
inboxPreviousItem|Previous (Vim)|Inbox Triage|k|0|inboxPreviousItem|1|k
inboxOpenItem|Open (Vim)|Inbox Triage|o|0|inboxOpenItem|1|o
flagMode|Flag Mode|Paper Actions|f|0|enterFlagMode|1|f
tagMode|Tag Mode|Paper Actions|t|0|enterTagMode|1|t
tagDeleteMode|Tag Delete Mode|Paper Actions|t|2|enterTagDeleteMode|1|Shift+t
filterMode|Filter Mode|Paper Actions|/|0|enterFilterMode|1|/
pdfPageDown|Page Down|PDF Viewer|space|0|pdfPageDown|1|Space
pdfPageUp|Page Up|PDF Viewer|space|2|pdfPageUp|1|Shift+Space
pdfZoomIn|Zoom In|PDF Viewer|plus|3|pdfZoomIn|1|⇧⌘+
pdfZoomOut|Zoom Out|PDF Viewer|minus|3|pdfZoomOut|1|⇧⌘-
pdfGoToPage|Go to Page|PDF Viewer|g|1|pdfGoToPage|1|⌘g
importBibTeX|Import BibTeX|File Operations|i|1|importBibTeX|1|⌘i
exportBibTeX|Export Library|File Operations|e|3|exportBibTeX|1|⇧⌘e
refreshData|Refresh|File Operations|n|3|refreshData|1|⇧⌘n
showKeyboardShortcuts|Keyboard Shortcuts|App|/|1|showKeyboardShortcuts|1|⌘/
showNLSearch|Smart Search (AI)|App|s|1|showNLSearch|1|⌘s
"""#

    static let preMoveRenderedOrder = #"""
Navigation/navigateDown/j
Navigation/navigateUp/k
Navigation/cycleFocusLeft/h
Navigation/cycleFocusRight/l
Navigation/showInfoTabVim/i
Navigation/showPDFTabVim/p
Navigation/showNotesTabVim/n
Navigation/showBibTeXTabVim/b
Navigation/navigateNextPaper/↓
Navigation/navigatePreviousPaper/↑
Navigation/navigateFirstPaper/⌘↑
Navigation/navigateLastPaper/⌘↓
Navigation/navigateNextUnread/⌥↓
Navigation/navigatePreviousUnread/⌥↑
Navigation/navigateNextUnreadVim/⌥j
Navigation/navigatePreviousUnreadVim/⌥k
Navigation/openSelectedPaper/↩
Views/showLibrary/⌘1
Views/showSearch/⌘2
Views/showInbox/⌘3
Views/showPDFTab/⌘4
Views/showBibTeXTab/⌘5
Views/showNotesTab/⌘6
Views/toggleDetailPane/⌘0
Views/toggleSidebar/⌃⌘s
Focus/focusSidebar/⌥⌘1
Focus/focusList/⌥⌘2
Focus/focusDetail/⌥⌘3
Focus/focusSearch/⌘f
Paper Actions/showNotesTabR/⌘r
Paper Actions/openReferences/⇧⌘r
Paper Actions/toggleReadStatus/⇧⌘u
Paper Actions/markAllAsRead/⌥⌘u
Paper Actions/saveToLibrary/⌃⌘s
Paper Actions/dismissFromInbox/⇧⌘j
Paper Actions/addToCollection/⌘l
Paper Actions/removeFromCollection/⇧⌘l
Paper Actions/moveToCollection/⌃⌘m
Paper Actions/sharePapers/⇧⌘f
Paper Actions/deleteSelectedPapers/⌘⌫
Paper Actions/flagMode/f
Paper Actions/tagMode/t
Paper Actions/tagDeleteMode/Shift+t
Paper Actions/filterMode//
Clipboard/copyPublications/⌘c
Clipboard/copyAsCitation/⇧⌘c
Clipboard/copyIdentifier/⌥⌘c
Clipboard/cutPublications/⌘x
Clipboard/pastePublications/⌘v
Clipboard/selectAllPublications/⌘a
Filtering/toggleUnreadFilter/⌘\
Filtering/togglePDFFilter/⇧⌘\
Inbox Triage/inboxSave/*
Inbox Triage/inboxSaveAndStar/Shift+s
Inbox Triage/inboxToggleStar/s
Inbox Triage/inboxDismiss/d
Inbox Triage/inboxMarkRead/r
Inbox Triage/inboxMarkUnread/u
Inbox Triage/inboxNextItem/j
Inbox Triage/inboxPreviousItem/k
Inbox Triage/inboxOpenItem/o
PDF Viewer/pdfPageDown/Space
PDF Viewer/pdfPageUp/Shift+Space
PDF Viewer/pdfZoomIn/⇧⌘+
PDF Viewer/pdfZoomOut/⇧⌘-
PDF Viewer/pdfGoToPage/⌘g
File Operations/importBibTeX/⌘i
File Operations/exportBibTeX/⇧⌘e
File Operations/refreshData/⇧⌘n
App/showKeyboardShortcuts/⌘/
App/showNLSearch/⌘s
"""#

    static let preMoveConflicts = "navigateDown+inboxNextItem,navigateUp+inboxPreviousItem,toggleSidebar+saveToLibrary"
}
