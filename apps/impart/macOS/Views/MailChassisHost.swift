//
//  MailChassisHost.swift
//  impart (macOS)
//
//  Stage 4c: everything the chassis window needs that only impart can supply.
//
//  The chassis reads mail from the SHARED STORE (`MailStoreReader`, envelope
//  read/star flags, `email-message` payloads). impart's own model is CORE DATA,
//  and the store rows are a MIRROR of it written by `MailStoreMirror` — so for
//  any verb whose truth lives in Core Data or IMAP, the store is a replica and
//  the chassis must ask impart. Two such verbs blocked the flip:
//
//   1. COMPOSE. `ComposeView` is a Core Data / SMTP surface; the chassis has no
//      business knowing it exists. The mail descriptor now declares one
//      `CreationAffordance` and impart supplies the verb through
//      `RecordHostVerbs.onCreate`, so the chassis's own affordances — the `n`
//      key and the empty-state button — work, and so do ⌘N, the File menu and
//      `impart://compose` (all three post `.composeMessage`, which this modifier
//      is the first thing in impart's history to observe outside the classic
//      window).
//
//   2. MARK-READ ON SELECT. The classic window did this in
//      `MessageDetailView.loadMessage()` with a direct `CDMessage.isRead = true`
//      write from the view. Here it goes through `MessageTriageService.markRead`
//      — the verb that also names the undo action — plus a
//      `MailStoreMirror.setRead` so the chassis row the user is looking at loses
//      its unread dot immediately instead of at the next scope change.
//
//  The store item id is NOT `CDMessage.id`: mail rows carry a UUIDv5 derived
//  from the RFC Message-ID (`ImpartStoreAdapter.emailMessageRow`). The bridge is
//  `RecordSelection.externalID`, the payload `message_id`, matched against
//  `CDMessage.messageId`. That resolution is also what makes Reply/Forward
//  possible in this window — which is a capability RESTORED, not preserved:
//  classic's reply/forward lived on `MessageDetailView`, and that pane could
//  never appear, because it read `AppState.selectedMessageIds` while the message
//  list wrote `InboxViewModel.selectedMessageIds` (two unconnected sets).
//

import CoreData
import ImpressKit
import MessageManagerCore
import OSLog
import PublicationManagerCore
import SwiftUI

// MARK: - Host state

/// impart's side of the chassis mail selection.
///
/// A `@MainActor @Observable` SINGLETON rather than view state, for the same
/// reason `ImpartSurfaceContext` is one: `RecordHostVerbs`' closures are
/// `@Sendable`, and the chassis builds and discards surface/list views freely, so
/// anything they capture has to outlive a view and be safe to capture. Capturing
/// a main-actor-isolated class is both.
@MainActor
@Observable
final class ImpartMailHost {

    static let shared = ImpartMailHost()

    /// The Core Data message behind the chassis's current selection, when it
    /// resolves. `nil` for a store row impart has no `CDMessage` for — a
    /// mirrored row whose Core Data original was deleted, or a `chat-message`.
    private(set) var selectedMessage: Message?

    /// Body + attachments for `selectedMessage`, when it has content — reply and
    /// forward quote it (`DraftMessage.reply(to:accountId:content:)`).
    private(set) var selectedContent: MessageContent?

    /// The STORE item id of the current selection (not `CDMessage.id`) — what
    /// the mirror's `setMessagesRead` keys on.
    private(set) var selectedStoreID: UUID?

    private let persistence = PersistenceController.shared
    private let triage = MessageTriageService()

    private init() {}

    // MARK: Selection

    /// The chassis is now showing this record: resolve impart's own message
    /// (which is what makes Reply/Forward possible) and mark it read.
    ///
    /// The mark-read WRITE is guarded on `message.isRead`, not on the store's
    /// mirrored flag and not in the chassis: the write mirrors back as a store
    /// mutation → `StoreEvents` → list reload, so re-writing an already-read
    /// message is how selection would start pumping the list (CLAUDE.md's
    /// render-loop rule). The RESOLUTION is unguarded — it has to run for every
    /// selection or the reply target goes stale.
    func chassisDidSelect(_ selection: RecordSelection) {
        guard selection.kind == .message else { return }
        let storeID = selection.recordID
        let externalID = selection.externalID
        Task { await resolveAndMarkRead(storeID: storeID, externalID: externalID) }
    }

    private func resolveAndMarkRead(storeID: UUID, externalID: String?) async {
        selectedStoreID = storeID
        guard let externalID, !externalID.isEmpty else {
            // No RFC Message-ID in the payload: impart cannot identify its own
            // record, so it does NOT guess. The store row keeps its unread flag
            // — honest, and visible, rather than a silent half-write — and the
            // reply target is CLEARED rather than left pointing at whatever was
            // selected before (which is what disables Reply/Forward).
            selectedMessage = nil
            selectedContent = nil
            Logger.messages.info(
                "chassis selection \(storeID) has no message_id payload — read state not synced")
            return
        }

        let resolved = await loadMessage(messageIDHeader: externalID)
        selectedMessage = resolved.message
        selectedContent = resolved.content

        guard let message = resolved.message, !message.isRead else { return }
        // Core Data is the authority (undo action name included)…
        let result = triage.markRead(ids: [message.id])
        guard result.success else {
            Logger.messages.error(
                "mark-read failed for \(message.id): \(result.errorMessage ?? "unknown")")
            return
        }
        // …and the store mirror is brought level so the row the user is looking
        // at updates now, not on the next reload.
        MailStoreMirror.shared.setMessagesRead(
            itemIDs: [storeID.uuidString.lowercased()], read: true)
        Logger.messages.info(
            "chassis select → marked read: cd=\(message.id) store=\(storeID)")
    }

    /// Fetch impart's `CDMessage` (and its content) for an RFC Message-ID.
    private func loadMessage(
        messageIDHeader: String
    ) async -> (message: Message?, content: MessageContent?) {
        do {
            return try await persistence.performBackgroundTask { context in
                let request = CDMessage.fetchRequest()
                request.predicate = NSPredicate(format: "messageId == %@", messageIDHeader)
                request.fetchLimit = 1
                guard let cdMessage = try context.fetch(request).first else {
                    return (nil, nil)
                }
                let message = cdMessage.toMessage()
                guard let cdContent = cdMessage.content else { return (message, nil) }
                let attachments = (cdContent.attachments ?? []).map { cdAttachment in
                    Attachment(
                        id: cdAttachment.id,
                        filename: cdAttachment.filename,
                        mimeType: cdAttachment.mimeType,
                        size: Int(cdAttachment.size),
                        contentId: cdAttachment.contentId,
                        isInline: cdAttachment.isInline
                    )
                }
                return (message, MessageContent(
                    messageId: message.id,
                    textBody: cdContent.textBody,
                    htmlBody: cdContent.htmlBody,
                    attachments: attachments
                ))
            }
        } catch {
            Logger.messages.error(
                "failed to resolve message \(messageIDHeader): \(error.localizedDescription)")
            return (nil, nil)
        }
    }

    // MARK: Read state (Message menu)

    /// Message ▸ Mark as Read / Mark as Unread for the chassis's selection.
    ///
    /// These two menu items posted `.markAsRead` / `.markAsUnread` into a repo
    /// with no observer at all before Stage 4c — dead menu items in both windows.
    /// They go through the same `MessageTriageService` verb as selection does, so
    /// undo names and the store mirror stay consistent.
    func setReadStateOnSelection(_ read: Bool) {
        guard let message = selectedMessage, let storeID = selectedStoreID else { return }
        let result = read ? triage.markRead(ids: [message.id]) : triage.markUnread(ids: [message.id])
        guard result.success else {
            Logger.messages.error(
                "mark-\(read ? "read" : "unread") failed: \(result.errorMessage ?? "unknown")")
            return
        }
        MailStoreMirror.shared.setMessagesRead(
            itemIDs: [storeID.uuidString.lowercased()], read: read)
        // Keep the in-memory snapshot level with the write so the toolbar and a
        // follow-up selection agree with the store.
        selectedMessage = message.withReadState(read)
    }

    // MARK: Drafts

    /// Reply draft for the current selection, or nil when nothing resolves.
    func replyDraft() -> DraftMessage? {
        guard let message = selectedMessage else { return nil }
        return DraftMessage.reply(
            to: message, accountId: message.accountId, content: selectedContent)
    }

    /// Forward draft for the current selection, or nil when nothing resolves.
    func forwardDraft() -> DraftMessage? {
        guard let message = selectedMessage else { return nil }
        return DraftMessage.forward(
            message: message, accountId: message.accountId, content: selectedContent)
    }
}

// MARK: - Read-state snapshot

private extension Message {
    /// A copy with a different read flag. `Message` is a value type with no
    /// mutating setters, and the classic `MessageDetailView.toggleRead()` rebuilt
    /// all eighteen fields inline for exactly this; doing it once, here, keeps the
    /// field list in one place.
    func withReadState(_ read: Bool) -> Message {
        Message(
            id: id, accountId: accountId, mailboxId: mailboxId, uid: uid,
            messageId: messageId, inReplyTo: inReplyTo, references: references,
            subject: subject, from: from, to: to, cc: cc, bcc: bcc,
            date: date, receivedDate: receivedDate, snippet: snippet,
            isRead: read, isStarred: isStarred, hasAttachments: hasAttachments,
            labels: labels)
    }
}

// MARK: - Host modifier

/// The chassis window's mail host: registers impart's `RecordHostVerbs`, hosts
/// the compose sheet, contributes the mail toolbar, and observes the app-level
/// notifications that used to be handled by the classic `ContentView`.
struct MailChassisHost: ViewModifier {

    @Environment(AppState.self) private var appState
    private var host: ImpartMailHost { .shared }

    /// Kept in sync with `MessageViewMode` so the ⌘1-5 accelerators land where
    /// the classic view-mode picker did: mode → the chassis destination that
    /// shows the same thing. `.email` is the Mail SECTION (the shell's default
    /// landing leaf, All Inboxes); the other four are registered surfaces.
    static func chassisDestination(for mode: MessageViewMode) -> String? {
        switch mode {
        case .email: return nil            // → default section
        case .chat: return "chat"
        case .category: return "category"
        case .research: return "research"
        case .development: return "development"
        }
    }

    func body(content: Content) -> some View {
        @Bindable var appState = appState

        content
            // The two verbs the chassis declares but cannot perform. `onCreate`
            // posts rather than mutating `appState` directly so compose has ONE
            // entry point: whatever route asked (n, ⌘N, File menu, URL scheme),
            // the same handler builds the draft.
            .environment(\.recordHostVerbs, RecordHostVerbRegistry([
                .message: RecordHostVerbs(
                    onCreate: { _ in
                        NotificationCenter.default.post(name: .composeMessage, object: nil)
                    },
                    onSelect: { selection in
                        ImpartMailHost.shared.chassisDidSelect(selection)
                    })
            ]))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(name: .composeMessage, object: nil)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("Compose New Message (⌘N)")

                    Button {
                        NotificationCenter.default.post(name: .replyToMessage, object: nil)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left")
                    }
                    .help("Reply (⌘R)")
                    .disabled(host.selectedMessage == nil)

                    Button {
                        NotificationCenter.default.post(name: .forwardMessage, object: nil)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.right")
                    }
                    .help("Forward (⌘⇧F)")
                    .disabled(host.selectedMessage == nil)

                    Button {
                        NotificationCenter.default.post(name: .checkMail, object: nil)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Check for New Mail (⌘⇧N)")
                }
            }
            .sheet(isPresented: $appState.isComposing) {
                ComposeView(draft: appState.currentDraft)
            }
            .onNotifications([
                // Compose: ⌘N / File ▸ New Message / impart://compose / the
                // chassis's own `n` key and empty-state button.
                (.composeMessage, { notification in handleCompose(notification) }),
                // Reply / Forward — the Message menu items that had NO observer
                // anywhere in impart before this (their only handler lived on
                // the unreachable classic detail pane).
                (.replyToMessage, { _ in present(draft: host.replyDraft()) }),
                (.replyAllToMessage, { _ in present(draft: host.replyDraft()) }),
                (.forwardMessage, { _ in present(draft: host.forwardDraft()) }),
                // Message ▸ Mark as Read / Unread — also observer-less before 4c.
                (.markAsRead, { _ in host.setReadStateOnSelection(true) }),
                (.markAsUnread, { _ in host.setReadStateOnSelection(false) }),
                (.checkMail, { _ in checkMail() }),
                // ⌘1-5 view modes → chassis navigation (ImpartApp's View menu).
                (.switchToEmailView, { _ in navigate(to: .email) }),
                (.switchToChatView, { _ in navigate(to: .chat) }),
                (.switchToCategoryView, { _ in navigate(to: .category) }),
                (.switchToResearchView, { _ in navigate(to: .research) }),
                (.switchToDevelopmentView, { _ in navigate(to: .development) }),
            ])
    }

    // MARK: Handlers

    /// Moved from `ContentView.handleComposeNotification` — same shape, same
    /// `userInfo` keys (`impart://compose?to=&subject=&body=`).
    private func handleCompose(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            let to = (userInfo["to"] as? String).map { [EmailAddress(email: $0)] } ?? []
            let subject = userInfo["subject"] as? String ?? ""
            let body = userInfo["body"] as? String ?? ""

            if let accountId = appState.selectedAccountId {
                appState.currentDraft = DraftMessage(
                    accountId: accountId, to: to, subject: subject, body: body)
            }
        }
        appState.isComposing = true
    }

    private func present(draft: DraftMessage?) {
        guard let draft else { return }
        appState.currentDraft = draft
        appState.isComposing = true
    }

    /// IMAP fetch for the selected account/mailbox. Identical reach to the
    /// classic toolbar's refresh button: `InboxViewModel.refresh()` returns early
    /// until an account exists (see AccountsSettingsView's note), so this is
    /// wired, not yet productive.
    private func checkMail() {
        Task { await ImpartSurfaceContext.shared.inboxViewModel.refresh() }
    }

    private func navigate(to mode: MessageViewMode) {
        if let surfaceID = Self.chassisDestination(for: mode) {
            NotificationCenter.default.post(
                name: .chassisNavigateToSurface, object: surfaceID)
        } else {
            NotificationCenter.default.post(
                name: .chassisNavigateToDefaultSection, object: nil)
        }
    }
}
