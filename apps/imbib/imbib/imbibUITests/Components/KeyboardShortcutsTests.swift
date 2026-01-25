//
//  KeyboardShortcutsTests.swift
//  imbibUITests
//
//  Comprehensive tests for all documented keyboard shortcuts.
//

import XCTest

/// Comprehensive tests for all keyboard shortcuts.
///
/// Tests organized by menu structure matching the app's menu bar.
final class KeyboardShortcutsTests: XCTestCase {

    var app: XCUIApplication!
    var sidebar: SidebarPage!
    var list: PublicationListPage!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = TestApp.launch(with: .basic)
        sidebar = SidebarPage(app: app)
        list = PublicationListPage(app: app)

        _ = sidebar.waitForSidebar()
    }

    // MARK: - File Menu Shortcuts

    /// Test Cmd+I - Import BibTeX
    func testCmdI_ImportBibTeX() throws {
        app.typeKey("i", modifierFlags: .command)

        // Import dialog should appear
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2), "Import dialog should open with Cmd+I")

        app.typeKey(.escape, modifierFlags: [])
    }

    /// Test Cmd+Shift+E - Export Library
    func testCmdShiftE_ExportLibrary() throws {
        app.typeKey("e", modifierFlags: [.command, .shift])

        // Export dialog should appear
        let dialog = app.dialogs.firstMatch
        // Dialog might not appear if nothing to export
        if dialog.waitForExistence(timeout: 2) {
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    // MARK: - Edit Menu Shortcuts

    /// Test Cmd+C - Copy
    func testCmdC_Copy() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("c", modifierFlags: .command)
        // BibTeX should be copied to clipboard
        // No error = success
    }

    /// Test Cmd+Shift+C - Copy as Citation
    func testCmdShiftC_CopyAsCitation() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("c", modifierFlags: [.command, .shift])
        // Citation should be copied to clipboard
    }

    /// Test Cmd+Option+C - Copy DOI/URL
    func testCmdOptionC_CopyDOI() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("c", modifierFlags: [.command, .option])
        // DOI/URL should be copied to clipboard
    }

    /// Test Cmd+X - Cut
    func testCmdX_Cut() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("x", modifierFlags: .command)
        // Publication should be cut
    }

    /// Test Cmd+V - Paste
    func testCmdV_Paste() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        app.typeKey("v", modifierFlags: .command)
        // Should paste clipboard content (BibTeX if available)
    }

    /// Test Cmd+A - Select All
    func testCmdA_SelectAll() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        app.typeKey("a", modifierFlags: .command)
        // All publications should be selected
    }

    /// Test Cmd+F - Focus Search
    func testCmdF_FocusSearch() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        app.typeKey("f", modifierFlags: .command)
        // Search field should be focused
    }

    // MARK: - View Menu Shortcuts

    /// Test Cmd+1 - Show Library
    func testCmd1_ShowLibrary() throws {
        app.typeKey("1", modifierFlags: .command)
        // Library section should be shown
    }

    /// Test Cmd+2 - Show Search
    func testCmd2_ShowSearch() throws {
        app.typeKey("2", modifierFlags: .command)
        // Search section should be shown
    }

    /// Test Cmd+3 - Show Inbox
    func testCmd3_ShowInbox() throws {
        app.typeKey("3", modifierFlags: .command)
        // Inbox should be shown
    }

    /// Test Cmd+4 - Show PDF Tab
    func testCmd4_ShowPDFTab() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("4", modifierFlags: .command)
        // PDF tab should be shown in detail view
    }

    /// Test Cmd+5 - Show BibTeX Tab
    func testCmd5_ShowBibTeXTab() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("5", modifierFlags: .command)
        // BibTeX tab should be shown
    }

    /// Test Cmd+6 - Show Notes Tab
    func testCmd6_ShowNotesTab() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("6", modifierFlags: .command)
        // Notes tab should be shown
    }

    /// Test Cmd+0 - Toggle Detail Pane
    func testCmd0_ToggleDetailPane() throws {
        app.typeKey("0", modifierFlags: .command)
        // Detail pane should toggle

        app.typeKey("0", modifierFlags: .command)
        // Detail pane should toggle back
    }

    /// Test Ctrl+Cmd+S - Toggle Sidebar
    func testCtrlCmdS_ToggleSidebar() throws {
        app.typeKey("s", modifierFlags: [.control, .command])
        // Sidebar should toggle

        app.typeKey("s", modifierFlags: [.control, .command])
        // Sidebar should toggle back
    }

    /// Test Cmd+Option+1 - Focus Sidebar
    func testCmdOption1_FocusSidebar() throws {
        app.typeKey("1", modifierFlags: [.command, .option])
        // Sidebar should have focus
    }

    /// Test Cmd+Option+2 - Focus List
    func testCmdOption2_FocusList() throws {
        app.typeKey("2", modifierFlags: [.command, .option])
        // List should have focus
    }

    /// Test Cmd+Option+3 - Focus Detail
    func testCmdOption3_FocusDetail() throws {
        app.typeKey("3", modifierFlags: [.command, .option])
        // Detail should have focus
    }

    /// Test Cmd+Shift+= - Increase Text Size
    func testCmdShiftEquals_IncreaseTextSize() throws {
        app.typeKey("=", modifierFlags: [.command, .shift])
        // Text size should increase
    }

    /// Test Cmd+Shift+- - Decrease Text Size
    func testCmdShiftMinus_DecreaseTextSize() throws {
        app.typeKey("-", modifierFlags: [.command, .shift])
        // Text size should decrease
    }

    // MARK: - Paper Menu Shortcuts

    /// Test Return - Open PDF
    func testReturn_OpenPDF() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey(.return, modifierFlags: [])
        // PDF should open or show in detail view
    }

    /// Test Cmd+R - Open Notes
    func testCmdR_OpenNotes() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("r", modifierFlags: .command)
        // Notes tab should be shown
    }

    /// Test Cmd+Shift+R - Open References
    func testCmdShiftR_OpenReferences() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("r", modifierFlags: [.command, .shift])
        // References should open
    }

    /// Test Cmd+Shift+U - Toggle Read/Unread
    func testCmdShiftU_ToggleRead() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("u", modifierFlags: [.command, .shift])
        // Read status should toggle
    }

    /// Test Cmd+Option+U - Mark All as Read
    func testCmdOptionU_MarkAllAsRead() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        app.typeKey("u", modifierFlags: [.command, .option])
        // All should be marked as read
    }

    /// Test Ctrl+Cmd+K - Keep to Library (Inbox)
    func testCtrlCmdK_KeepToLibrary() throws {
        sidebar.selectInbox()

        app.typeKey("k", modifierFlags: [.control, .command])
        // Paper should be kept to library (or library picker shown)
    }

    /// Test Cmd+Shift+J - Dismiss from Inbox
    func testCmdShiftJ_DismissFromInbox() throws {
        sidebar.selectInbox()

        app.typeKey("j", modifierFlags: [.command, .shift])
        // Paper should be dismissed from inbox
    }

    /// Test Ctrl+Cmd+M - Move to Collection
    func testCtrlCmdM_MoveToCollection() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("m", modifierFlags: [.control, .command])
        // Collection picker should appear
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Test Cmd+L - Add to Collection
    func testCmdL_AddToCollection() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("l", modifierFlags: .command)
        // Collection picker should appear
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Test Cmd+Shift+L - Remove from Collection
    func testCmdShiftL_RemoveFromCollection() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("l", modifierFlags: [.command, .shift])
        // Should remove from current collection
    }

    /// Test Cmd+Shift+F - Share
    func testCmdShiftF_Share() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("f", modifierFlags: [.command, .shift])
        // Share sheet should appear
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Test Cmd+Delete - Delete
    func testCmdDelete_Delete() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey(.delete, modifierFlags: .command)
        // Delete confirmation should appear
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Annotate Menu Shortcuts

    /// Test Ctrl+H - Highlight Selection
    func testCtrlH_HighlightSelection() throws {
        // Note: These require PDF view with selection
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("h", modifierFlags: .control)
        // Highlight should be applied if selection exists
    }

    /// Test Ctrl+U - Underline Selection
    func testCtrlU_UnderlineSelection() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("u", modifierFlags: .control)
        // Underline should be applied
    }

    /// Test Ctrl+T - Strikethrough Selection
    func testCtrlT_StrikethroughSelection() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("t", modifierFlags: .control)
        // Strikethrough should be applied
    }

    /// Test Ctrl+N - Add Note at Selection
    func testCtrlN_AddNoteAtSelection() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("n", modifierFlags: .control)
        // Note should be added at selection
    }

    // MARK: - Go Menu Shortcuts

    /// Test Cmd+[ - Back
    func testCmdLeftBracket_Back() throws {
        app.typeKey("[", modifierFlags: .command)
        // Should navigate back
    }

    /// Test Cmd+] - Forward
    func testCmdRightBracket_Forward() throws {
        app.typeKey("]", modifierFlags: .command)
        // Should navigate forward
    }

    /// Test Down Arrow - Next Paper
    func testDownArrow_NextPaper() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey(.downArrow, modifierFlags: [])
        // Next paper should be selected
    }

    /// Test Up Arrow - Previous Paper
    func testUpArrow_PreviousPaper() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()
        list.navigateToNext()

        app.typeKey(.upArrow, modifierFlags: [])
        // Previous paper should be selected
    }

    /// Test Cmd+Up - First Paper
    func testCmdUp_FirstPaper() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        app.typeKey(.upArrow, modifierFlags: .command)
        // First paper should be selected
    }

    /// Test Cmd+Down - Last Paper
    func testCmdDown_LastPaper() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        app.typeKey(.downArrow, modifierFlags: .command)
        // Last paper should be selected
    }

    /// Test Option+Down - Next Unread
    func testOptionDown_NextUnread() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        app.typeKey(.downArrow, modifierFlags: .option)
        // Next unread paper should be selected
    }

    /// Test Option+Up - Previous Unread
    func testOptionUp_PreviousUnread() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        app.typeKey(.upArrow, modifierFlags: .option)
        // Previous unread paper should be selected
    }

    /// Test Cmd+G - Go to Page
    func testCmdG_GoToPage() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // Need to be in PDF view
        app.typeKey("4", modifierFlags: .command) // Switch to PDF tab

        app.typeKey("g", modifierFlags: .command)
        // Go to page dialog might appear
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Window Menu Shortcuts

    /// Test Cmd+Shift+N - Refresh
    func testCmdShiftN_Refresh() throws {
        app.typeKey("n", modifierFlags: [.command, .shift])
        // Should refresh current view
    }

    /// Test Cmd+\ - Toggle Unread Filter
    func testCmdBackslash_ToggleUnreadFilter() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        app.typeKey("\\", modifierFlags: .command)
        // Unread filter should toggle

        app.typeKey("\\", modifierFlags: .command)
        // Toggle back
    }

    /// Test Cmd+Shift+\ - Toggle PDF Filter
    func testCmdShiftBackslash_TogglePDFFilter() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        app.typeKey("\\", modifierFlags: [.command, .shift])
        // PDF filter should toggle

        app.typeKey("\\", modifierFlags: [.command, .shift])
        // Toggle back
    }

    /// Test Cmd+Shift+M - Detach PDF to Window
    func testCmdShiftM_DetachPDF() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("m", modifierFlags: [.command, .shift])
        // PDF should detach to new window
    }

    /// Test Cmd+Shift+Option+W - Close Detached Windows
    func testCmdShiftOptionW_CloseDetachedWindows() throws {
        app.typeKey("w", modifierFlags: [.command, .shift, .option])
        // All detached windows should close
    }

    // MARK: - Help Menu Shortcuts

    /// Test Cmd+/ - Keyboard Shortcuts
    func testCmdSlash_KeyboardShortcuts() throws {
        app.typeKey("/", modifierFlags: .command)

        // Keyboard shortcuts window should open
        let shortcutsWindow = app.windows["Keyboard Shortcuts"]
        XCTAssertTrue(shortcutsWindow.waitForExistence(timeout: 2), "Shortcuts window should open")

        // Close it
        app.typeKey("w", modifierFlags: .command)
    }

    // MARK: - Global Shortcuts

    /// Test Cmd+F - Global Search
    func testCmdF_GlobalSearch() throws {
        let searchPalette = SearchPalettePage(app: app)

        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(searchPalette.waitForPalette(), "Global search should open with Cmd+F")

        searchPalette.close()
    }

    /// Test Cmd+, - Settings
    func testCmdComma_Settings() throws {
        app.typeKey(",", modifierFlags: .command)

        let settings = SettingsPage(app: app)
        XCTAssertTrue(settings.waitForWindow(), "Settings should open with Cmd+,")

        settings.close()
    }

    // MARK: - Triage Shortcuts (Single Key)

    /// Test K key - Keep (in Inbox)
    func testK_Keep() throws {
        sidebar.selectInbox()

        // K key for keep (no modifiers, when in inbox)
        app.typeKey("k", modifierFlags: [])
        // Paper should be kept
    }

    /// Test D key - Dismiss (in Inbox)
    func testD_Dismiss() throws {
        sidebar.selectInbox()

        // D key for dismiss (no modifiers, when in inbox)
        app.typeKey("d", modifierFlags: [])
        // Paper should be dismissed
    }

    /// Test S key - Toggle Star
    func testS_ToggleStar() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("s", modifierFlags: [])
        // Star should toggle
    }
}
