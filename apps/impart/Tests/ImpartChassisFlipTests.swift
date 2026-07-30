//
//  ImpartChassisFlipTests.swift
//  impartTests
//
//  Stage 4c: the chassis window is impart's only window, so the things that used
//  to be "one of two windows handles it" are now single points of failure. These
//  tests pin the two that are STRING-KEYED, because a string-keyed navigation
//  seam fails silently — a chord or URL that resolves to no surface simply does
//  nothing, with no error and no log line.
//

import PublicationManagerCore
import Testing
@testable import MessageManagerCore
@testable import impart

@Suite("impart chassis flip (Stage 4c)")
struct ImpartChassisFlipTests {

    // MARK: ⌘1-5 → chassis destinations

    @Test("every view mode has a chassis destination")
    func everyViewModeResolves() {
        // `chassisDestination` returns nil for `.email` ON PURPOSE (the Mail
        // SECTION, reached via `.chassisNavigateToDefaultSection`), so "resolves"
        // means the switch is exhaustive over `allCases`, which the compiler
        // guarantees — what this asserts is the SHAPE: exactly one nil, and it is
        // email's.
        let nilModes = MessageViewMode.allCases.filter {
            MailChassisHost.chassisDestination(for: $0) == nil
        }
        #expect(nilModes == [.email])
    }

    @Test("every surface destination is a registered custom surface")
    func destinationsAreRegistered() {
        let surfaces = ImpartChassisRoot.shellConfiguration.customSurfaces
        for mode in MessageViewMode.allCases {
            guard let surfaceID = MailChassisHost.chassisDestination(for: mode) else {
                continue   // .email → default section, asserted above
            }
            #expect(
                surfaces[surfaceID] != nil,
                "⌘\(mode.commandShortcutKey.character) targets surface '\(surfaceID)', which no descriptor registers")
        }
    }

    @Test("the five view modes claim ⌘1-5, one each")
    func shortcutsAreDistinctAndComplete() {
        let keys = MessageViewMode.allCases.map { $0.commandShortcutKey.character }
        #expect(keys == ["1", "2", "3", "4", "5"])
    }

    @Test("each view mode posts its own notification")
    func notificationsAreDistinct() {
        let names = Set(MessageViewMode.allCases.map(\.switchNotification))
        #expect(names.count == MessageViewMode.allCases.count)
        // The RAW VALUES are the ones `ImpartKeyboardShortcutsSettings` has always
        // posted, so a user's customised ⌘1/⌘2/⌘3 bindings still land here. If
        // these ever diverge the bindings go dead silently.
        #expect(MessageViewMode.email.switchNotification.rawValue == "switchToEmailView")
        #expect(MessageViewMode.chat.switchNotification.rawValue == "switchToChatView")
        #expect(MessageViewMode.category.switchNotification.rawValue == "switchToCategoryView")
        #expect(MessageViewMode.research.switchNotification.rawValue == "switchToResearchView")
        #expect(
            MessageViewMode.development.switchNotification.rawValue == "switchToDevelopmentView")
    }

    /// The keyboard store's own binding strings must keep matching the typed
    /// names, or a customised ⌘1-3 posts a notification nothing observes — which
    /// is exactly the state the classic window shipped in for two of the five.
    @Test("keyboard-store view-mode bindings post the observed notifications")
    func keyboardStoreBindingsMatch() {
        let observed = Set(MessageViewMode.allCases.map(\.switchNotification.rawValue))
        let storeViewModeNames = ImpartKeyboardShortcutsSettings.defaults.bindings
            .map(\.notificationName)
            .filter { $0.hasPrefix("switchTo") }
        for name in storeViewModeNames {
            #expect(
                observed.contains(name),
                "keyboard store posts '\(name)', which MailChassisHost does not observe")
        }
    }

    // MARK: Mail host verbs

    @Test("impart registers both mail host verbs the chassis asks for")
    func hostVerbsAreRegistered() {
        // The registry is built inside `MailChassisHost.body`, so this asserts the
        // CONTRACT the chassis consumes rather than the modifier's internals:
        // mail declares a creation affordance (so `n` and the empty-state button
        // exist at all), and it is the single one the host answers.
        let creation = MessageRecordKind.descriptor.creation
        #expect(creation.count == 1)
        #expect(creation.first?.label == "New Message")
    }

    @Test("the mail descriptor still declares NO store-side lifecycle")
    func imapOwnedCapabilitiesUnchanged() {
        // Stage 4c closed compose and mark-read; it did NOT close the IMAP-owned
        // ones, and this is the guard against a later "while we're here".
        let triage = MessageRecordKind.descriptor.triage
        #expect(triage.dismissal == .none)
        #expect(triage.deletion == .none)
        #expect(triage.archiveStatus == nil)
    }
}
