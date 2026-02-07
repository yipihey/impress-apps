//
//  MailStylePublicationRow.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-05.
//

import SwiftUI
import UniformTypeIdentifiers
import ImpressFTUI
import ImpressKit

// MARK: - Browser Destination

/// Destinations for "Open in Browser" context menu action
public enum BrowserDestination: String, CaseIterable {
    case arxiv
    case ads
    case doi
    case publisher

    public var displayName: String {
        switch self {
        case .arxiv: return "View on arXiv"
        case .ads: return "View on ADS"
        case .doi: return "View Publisher (DOI)"
        case .publisher: return "View Publisher"
        }
    }

    public var systemImage: String {
        switch self {
        case .arxiv: return "doc.text"
        case .ads: return "star"
        case .doi: return "link"
        case .publisher: return "globe"
        }
    }
}

// MARK: - UUID Transferable Extension

extension UTType {
    /// UTType for dragging publication UUIDs between views
    public static let publicationID = UTType(exportedAs: "com.imbib.publication-id")

    /// UTType for dragging collection UUIDs between views (for nesting)
    public static let collectionID = UTType(exportedAs: "com.imbib.collection-id")

    /// UTType for dragging library UUIDs between views (for reordering)
    public static let libraryID = UTType(exportedAs: "com.imbib.library-id")

    /// UTType for dragging inbox feed UUIDs (for reordering)
    public static let inboxFeedID = UTType(exportedAs: "com.imbib.inbox-feed-id")

    /// UTType for dragging search form types (for reordering)
    public static let searchFormID = UTType(exportedAs: "com.imbib.search-form-id")

    /// UTType for dragging SciX library UUIDs (for reordering)
    public static let scixLibraryID = UTType(exportedAs: "com.imbib.scix-library-id")

    /// UTType for dragging sidebar section types (for reordering)
    public static let sidebarSectionID = UTType(exportedAs: "com.imbib.sidebar-section-id")

    /// UTType for dragging exploration search UUIDs (for reordering)
    public static let explorationSearchID = UTType(exportedAs: "com.imbib.exploration-search-id")

    /// UTType for dragging flag color items (for reordering)
    public static let flagColorID = UTType(exportedAs: "com.imbib.flag-color-id")
}

extension UUID: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .publicationID)
    }
}

/// A publication row styled after Apple Mail message rows
///
/// Layout:
/// ```
/// ┌─────────────────────────────────────────────────────────────┐
/// │ ● │ Einstein, A. · 1905                              42 │
/// │   │ On the Electrodynamics of Moving Bodies                │
/// │   │ 📎 We consider Maxwell's equations in a moving frame...│
/// └─────────────────────────────────────────────────────────────┘
/// ```
///
/// - Row 1: Blue dot (unread) | Authors (bold) · Year | Citation count (right-aligned)
/// - Row 2: Title
/// - Row 3: Paperclip icon (if PDF) | Abstract preview (2 lines max)
///
/// ## Thread Safety
///
/// This view accepts `PublicationRowData` (a value type) instead of `CDPublication`
/// directly. This eliminates crashes during bulk deletion where Core Data objects
/// become invalid while SwiftUI is still rendering.
///
/// ## Performance
///
/// This view conforms to `Equatable` to prevent unnecessary re-renders when parent
/// views rebuild. SwiftUI compares only `data` and `settings` - closures are ignored
/// since they don't affect visual output.
public struct MailStylePublicationRow: View, Equatable {

    // MARK: - Equatable

    public static func == (lhs: MailStylePublicationRow, rhs: MailStylePublicationRow) -> Bool {
        // Compare all properties that affect visual output (closures are excluded as they don't affect rendering)
        // Note: collections.count is compared rather than full equality for performance - only count changes matter for badge display
        lhs.data == rhs.data &&
        lhs.settings == rhs.settings &&
        lhs.isInInbox == rhs.isInInbox &&
        lhs.hasPDF == rhs.hasPDF &&
        lhs.collections.count == rhs.collections.count &&
        lhs.recommendationScore == rhs.recommendationScore &&
        lhs.highlightedCitationCount == rhs.highlightedCitationCount &&
        lhs.triageFlashColor == rhs.triageFlashColor
    }

    // MARK: - Environment

    @Environment(\.themeColors) private var theme
    @Environment(\.fontScale) private var fontScale

    // MARK: - Properties

    /// Immutable snapshot of publication data for display
    public let data: PublicationRowData

    /// List view settings controlling display options
    public var settings: ListViewSettings = .default

    /// Action when toggle read/unread is requested
    public var onToggleRead: (() -> Void)?

    /// Action when a category chip is tapped
    public var onCategoryTap: ((String) -> Void)?

    /// Action when files are dropped onto this row for attachment
    public var onFileDrop: (([NSItemProvider]) -> Void)?

    // MARK: - Swipe Action Callbacks (iOS)

    /// Action when delete is requested (swipe left)
    public var onDelete: (() -> Void)?

    /// Action when save is requested (swipe right)
    public var onSave: (() -> Void)?

    /// Action when dismiss is requested (swipe left, Inbox only)
    public var onDismiss: (() -> Void)?

    /// Action when toggling star is requested
    public var onToggleStar: (() -> Void)?

    /// Action when a flag color is set
    public var onSetFlag: ((FlagColor) -> Void)?

    /// Action when flag is cleared
    public var onClearFlag: (() -> Void)?

    /// Action when adding a tag is requested
    public var onAddTag: (() -> Void)?

    /// Action when removing a tag is requested (by tag ID)
    public var onRemoveTag: ((UUID) -> Void)?

    /// Whether this paper is in the Inbox (enables Inbox-specific actions)
    public var isInInbox: Bool = false

    // MARK: - Context Menu Callbacks

    /// Action when Open PDF is requested
    public var onOpenPDF: (() -> Void)?

    /// Action when Copy Cite Key is requested
    public var onCopyCiteKey: (() -> Void)?

    /// Action when Copy BibTeX is requested
    public var onCopyBibTeX: (() -> Void)?

    /// Action when adding to a collection is requested
    public var onAddToCollection: ((CDCollection) -> Void)?

    /// Action when muting author is requested
    public var onMuteAuthor: (() -> Void)?

    /// Action when muting this paper is requested
    public var onMutePaper: (() -> Void)?

    /// Available collections for "Add to Collection" menu
    public var collections: [CDCollection] = []

    /// Whether the publication has an attached PDF
    public var hasPDF: Bool = false

    // MARK: - New Context Menu Callbacks

    /// Action when Open in Browser is requested (arXiv, ADS, DOI)
    public var onOpenInBrowser: ((BrowserDestination) -> Void)?

    /// Action when Download PDF is requested
    public var onDownloadPDF: (() -> Void)?

    /// Action when View/Edit BibTeX is requested
    public var onViewEditBibTeX: (() -> Void)?

    /// Action when Share (system share sheet) is requested
    public var onShare: (() -> Void)?

    /// Action when Share by Email is requested (with PDF + BibTeX attachments)
    public var onShareByEmail: (() -> Void)?

    /// Action when Explore References is requested
    public var onExploreReferences: (() -> Void)?

    /// Action when Explore Citations is requested
    public var onExploreCitations: (() -> Void)?

    /// Action when Explore Similar Papers is requested
    public var onExploreSimilar: (() -> Void)?

    /// Action when adding to a library is requested
    public var onAddToLibrary: ((CDLibrary) -> Void)?

    /// Available libraries for "Add to Library" menu
    public var libraries: [CDLibrary] = []

    /// Action when Send to E-Ink Device is requested
    public var onSendToEInkDevice: (() -> Void)?

    /// Recommendation score to display (when sorting by recommended)
    public var recommendationScore: Double?

    /// Highlighted citation count to display (when sorting by citations)
    /// When set, shows citation count prominently with an icon, replacing the regular display
    public var highlightedCitationCount: Int?

    /// Flash color for triage feedback (green for keep, orange for dismiss)
    /// When non-nil, briefly shows a colored overlay to confirm the action
    public var triageFlashColor: Color?

    /// Holder for current selection (class reference avoids closure capture issues)
    /// When this item is dragged and is part of the selection, all selected items are dragged.
    public var dragSelectionHolder: DragSelectionHolder?

    /// Whether the row is currently a drop target
    @State private var isDropTargeted = false

    // MARK: - Computed Properties

    private var isUnread: Bool { !data.isRead }

    /// Author string with year for display
    private var authorYearString: String {
        if settings.showYear, let year = data.year {
            return "\(data.authorString) · \(year)"
        }
        return data.authorString
    }

    /// Content spacing based on row density
    private var contentSpacing: CGFloat {
        settings.rowDensity.contentSpacing
    }

    /// Row padding based on row density
    private var rowPadding: CGFloat {
        settings.rowDensity.rowPadding
    }

    // MARK: - Initialization

    public init(
        data: PublicationRowData,
        settings: ListViewSettings = .default,
        onToggleRead: (() -> Void)? = nil,
        onCategoryTap: ((String) -> Void)? = nil,
        onFileDrop: (([NSItemProvider]) -> Void)? = nil,
        // Swipe actions (iOS)
        onDelete: (() -> Void)? = nil,
        onSave: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        onToggleStar: (() -> Void)? = nil,
        onSetFlag: ((FlagColor) -> Void)? = nil,
        onClearFlag: (() -> Void)? = nil,
        onAddTag: (() -> Void)? = nil,
        onRemoveTag: ((UUID) -> Void)? = nil,
        isInInbox: Bool = false,
        // Context menu actions
        onOpenPDF: (() -> Void)? = nil,
        onCopyCiteKey: (() -> Void)? = nil,
        onCopyBibTeX: (() -> Void)? = nil,
        onAddToCollection: ((CDCollection) -> Void)? = nil,
        onMuteAuthor: (() -> Void)? = nil,
        onMutePaper: (() -> Void)? = nil,
        collections: [CDCollection] = [],
        hasPDF: Bool = false,
        // New context menu actions
        onOpenInBrowser: ((BrowserDestination) -> Void)? = nil,
        onDownloadPDF: (() -> Void)? = nil,
        onViewEditBibTeX: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        onShareByEmail: (() -> Void)? = nil,
        onExploreReferences: (() -> Void)? = nil,
        onExploreCitations: (() -> Void)? = nil,
        onExploreSimilar: (() -> Void)? = nil,
        onAddToLibrary: ((CDLibrary) -> Void)? = nil,
        libraries: [CDLibrary] = [],
        recommendationScore: Double? = nil,
        highlightedCitationCount: Int? = nil,
        triageFlashColor: Color? = nil,
        dragSelectionHolder: DragSelectionHolder? = nil
    ) {
        self.data = data
        self.settings = settings
        self.onToggleRead = onToggleRead
        self.onCategoryTap = onCategoryTap
        self.onFileDrop = onFileDrop
        // Swipe actions
        self.onDelete = onDelete
        self.onSave = onSave
        self.onDismiss = onDismiss
        self.onToggleStar = onToggleStar
        self.onSetFlag = onSetFlag
        self.onClearFlag = onClearFlag
        self.onAddTag = onAddTag
        self.onRemoveTag = onRemoveTag
        self.isInInbox = isInInbox
        // Context menu
        self.onOpenPDF = onOpenPDF
        self.onCopyCiteKey = onCopyCiteKey
        self.onCopyBibTeX = onCopyBibTeX
        self.onAddToCollection = onAddToCollection
        self.onMuteAuthor = onMuteAuthor
        self.onMutePaper = onMutePaper
        self.collections = collections
        self.hasPDF = hasPDF
        // New context menu
        self.onOpenInBrowser = onOpenInBrowser
        self.onDownloadPDF = onDownloadPDF
        self.onViewEditBibTeX = onViewEditBibTeX
        self.onShare = onShare
        self.onShareByEmail = onShareByEmail
        self.onExploreReferences = onExploreReferences
        self.onExploreCitations = onExploreCitations
        self.onExploreSimilar = onExploreSimilar
        self.onAddToLibrary = onAddToLibrary
        self.libraries = libraries
        self.recommendationScore = recommendationScore
        self.highlightedCitationCount = highlightedCitationCount
        self.triageFlashColor = triageFlashColor
        self.dragSelectionHolder = dragSelectionHolder
    }

    // MARK: - Body

    public var body: some View {
        // No guard needed - data is an immutable value type that cannot become invalid
        rowContent
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: MailStyleTokens.dotContentSpacing) {
            // Flag stripe (leading edge)
            if settings.showFlagStripe {
                FlagStripe(flag: data.flag, rowHeight: 44)
            }

            // Indicators column: unread dot and star
            if settings.showUnreadIndicator {
                VStack(spacing: 2) {
                    Circle()
                        .fill(isUnread ? MailStyleTokens.unreadDotColor(from: theme) : .clear)
                        .frame(
                            width: MailStyleTokens.unreadDotSize,
                            height: MailStyleTokens.unreadDotSize
                        )

                    if data.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10 * fontScale))
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(.top, 6)
            }

            // Content
            VStack(alignment: .leading, spacing: contentSpacing) {
                // Row 1: Authors [· Year] + [Date Added] [Citation Count]
                HStack {
                    Text(authorYearString)
                        .font(isUnread ? MailStyleTokens.authorFontUnread(scale: fontScale) : MailStyleTokens.authorFont(scale: fontScale))
                        .foregroundStyle(MailStyleTokens.primaryTextColor(from: theme))
                        .lineLimit(MailStyleTokens.authorLineLimit)

                    Spacer()

                    if settings.showDateAdded {
                        Text(MailStyleTokens.formatRelativeDate(data.dateAdded))
                            .font(MailStyleTokens.dateFont(scale: fontScale))
                            .foregroundStyle(MailStyleTokens.secondaryTextColor(from: theme))
                    }

                    // Recommendation score (when sorting by recommended)
                    if let score = recommendationScore {
                        HStack(spacing: 2) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9 * fontScale))
                            Text(String(format: "%.1f", score))
                                .font(MailStyleTokens.dateFont(scale: fontScale))
                        }
                        .foregroundStyle(theme.accent)
                    }

                    // Highlighted citation count (when sorting by citations)
                    if let citationCount = highlightedCitationCount {
                        HStack(spacing: 2) {
                            Image(systemName: "quote.bubble")
                                .font(.system(size: 9 * fontScale))
                            Text("\(citationCount)")
                                .font(MailStyleTokens.dateFont(scale: fontScale))
                        }
                        .foregroundStyle(theme.accent)
                    } else if settings.showCitationCount && data.citationCount > 0 {
                        // Regular citation count display (when not sorting by citations)
                        Text("\(data.citationCount)")
                            .font(MailStyleTokens.dateFont(scale: fontScale))
                            .foregroundStyle(MailStyleTokens.secondaryTextColor(from: theme))
                    }
                }

                // Row 2: Title (conditional)
                if settings.showTitle {
                    Text(data.title)
                        .font(MailStyleTokens.titleFont(scale: fontScale))
                        .fontWeight(isUnread ? .medium : .regular)
                        .foregroundStyle(MailStyleTokens.primaryTextColor(from: theme))
                        .lineLimit(MailStyleTokens.titleLineLimit)
                }

                // Row 2.5: Venue (conditional)
                if settings.showVenue, let venue = data.venue, !venue.isEmpty {
                    Text(venue)
                        .font(MailStyleTokens.abstractFont(scale: fontScale))
                        .foregroundStyle(MailStyleTokens.secondaryTextColor(from: theme))
                        .lineLimit(1)
                }

                // Row 2.7: Tags (conditional)
                if !data.tagDisplays.isEmpty {
                    TagLine(tags: data.tagDisplays, style: settings.tagDisplayStyle, pathStyle: settings.tagPathStyle)
                }

                // Row 2.75: Category chips disabled for performance
                // CategoryChipsRow creates multiple views per row which impacts scroll performance
                // Categories are still visible in the detail view

                // Row 3: Attachment indicator + Abstract preview (conditional)
                let hasAttachments = data.hasDownloadedPDF || data.hasOtherAttachments
                if (settings.showAttachmentIndicator && hasAttachments) || settings.abstractLineLimit > 0 {
                    HStack(spacing: 4) {
                        if settings.showAttachmentIndicator {
                            // Paperclip for downloaded PDFs
                            if data.hasDownloadedPDF {
                                Image(systemName: "paperclip")
                                    .font(MailStyleTokens.attachmentFont(scale: fontScale))
                                    .foregroundStyle(MailStyleTokens.tertiaryTextColor(from: theme))
                            }
                            // Document icon for other attachments (non-PDF files)
                            if data.hasOtherAttachments {
                                Image(systemName: "doc.fill")
                                    .font(MailStyleTokens.attachmentFont(scale: fontScale))
                                    .foregroundStyle(MailStyleTokens.tertiaryTextColor(from: theme))
                            }
                        }

                        if settings.abstractLineLimit > 0, let abstract = data.abstract, !abstract.isEmpty {
                            // PERFORMANCE: Plain text with truncation - AbstractRenderer
                            // is only used in detail view where formatting matters
                            Text(String(abstract.prefix(300)))
                                .font(MailStyleTokens.abstractFont(scale: fontScale))
                                .foregroundStyle(MailStyleTokens.secondaryTextColor(from: theme))
                                .lineLimit(settings.abstractLineLimit)
                        }
                    }
                }
            }
        }
        .padding(.vertical, rowPadding)
        .contentShape(Rectangle())
        // Multi-selection drag: read current selection from holder at drag time
        .itemProvider {
            // Read current selection from holder (class reference, not captured value)
            let currentSelection = dragSelectionHolder?.selectedIDs ?? []
            let idsToDrag: [UUID] = if currentSelection.contains(data.id) && currentSelection.count > 1 {
                Array(currentSelection)
            } else {
                [data.id]
            }

            let provider = NSItemProvider()
            // Encode all UUIDs as JSON array in a single representation
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.publicationID.identifier,
                visibility: .all
            ) { completion in
                // Encode as JSON array of UUID strings
                let uuidStrings = idsToDrag.map { $0.uuidString }
                let jsonData = try? JSONEncoder().encode(uuidStrings)
                completion(jsonData, nil)
                return nil
            }
            // Register cross-app ImpressPaperRef representation
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.impressPaperReference.identifier,
                visibility: .all
            ) { completion in
                let ref = ImpressPaperRef(
                    id: data.id,
                    citeKey: data.citeKey ?? data.id.uuidString,
                    title: data.title,
                    doi: data.doi
                )
                let jsonData = try? JSONEncoder().encode(ref)
                completion(jsonData, nil)
                return nil
            }
            // Set suggested name for drag preview
            provider.suggestedName = idsToDrag.count > 1
                ? "\(idsToDrag.count) publications"
                : data.title
            return provider
        }
        .overlay {
            // Drop target visual feedback
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .onDrop(of: [.fileURL, .pdf], isTargeted: $isDropTargeted) { providers in
            guard let onFileDrop = onFileDrop else { return false }
            onFileDrop(providers)
            return true
        }
        .contextMenu {
            contextMenuContent
        }
        // Swipe actions (works on both iOS and macOS with trackpad)
        // Swipe LEFT (.trailing) = Dismiss (moves to dismissed library, like Mail archive)
        // Note: allowsFullSwipe is disabled to prevent gesture conflicts with
        // iOS NavigationSplitView navigation gestures on iPhone
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onDismiss = onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Label("Dismiss", systemImage: "xmark.circle")
                }
                .tint(.orange)
            }
        }
        // Swipe RIGHT (.leading) = Save + Star + Toggle Read
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            // Save (green, leftmost)
            if let onSave = onSave {
                Button {
                    onSave()
                } label: {
                    Label("Save", systemImage: "checkmark.circle")
                }
                .tint(.green)
            }

            // Star (yellow)
            if let onToggleStar = onToggleStar {
                Button {
                    onToggleStar()
                } label: {
                    Label(
                        data.isStarred ? "Unstar" : "Star",
                        systemImage: data.isStarred ? "star.slash" : "star"
                    )
                }
                .tint(.yellow)
            }

            // Toggle Read (blue)
            if let onToggleRead = onToggleRead {
                Button {
                    onToggleRead()
                } label: {
                    Label(
                        isUnread ? "Read" : "Unread",
                        systemImage: isUnread ? "envelope.open" : "envelope.badge"
                    )
                }
                .tint(.blue)
            }
        }
        // Triage flash feedback - overlay on top of everything including selection highlight
        .overlay {
            if let flashColor = triageFlashColor {
                RoundedRectangle(cornerRadius: 6)
                    .fill(flashColor.opacity(0.5))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        // SECTION 1: PDF Actions
        pdfActionsSection

        // SECTION 2: BibTeX
        if let onViewEditBibTeX = onViewEditBibTeX {
            Button {
                onViewEditBibTeX()
            } label: {
                Label("View/Edit BibTeX", systemImage: "doc.plaintext")
            }

            Divider()
        }

        // SECTION 3: Share
        shareSection

        Divider()

        // SECTION 4: Read Status & Star
        if let onToggleRead = onToggleRead {
            Button {
                onToggleRead()
            } label: {
                Label(
                    isUnread ? "Mark as Read" : "Mark as Unread",
                    systemImage: isUnread ? "envelope.open" : "envelope.badge"
                )
            }
        }

        if let onToggleStar = onToggleStar {
            Button {
                onToggleStar()
            } label: {
                Label(
                    data.isStarred ? "Unstar" : "Star",
                    systemImage: data.isStarred ? "star.slash" : "star"
                )
            }
        }

        // Flag submenu
        if onSetFlag != nil || onClearFlag != nil {
            flagContextMenu
        }

        // Tag submenu
        if onAddTag != nil || onRemoveTag != nil {
            tagContextMenu
        }

        Divider()

        // SECTION 5: Organization (Libraries & Collections)
        organizationSection

        // SECTION 6: Explore (References, Citations, Similar)
        exploreSection

        // SECTION 7: Inbox-specific actions
        if isInInbox {
            Divider()
            inboxActionsSection
        }

        Divider()

        // SECTION 8: Delete
        if let onDelete = onDelete {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Context Menu Sections

    @ViewBuilder
    private var pdfActionsSection: some View {
        // Open PDF (if available)
        if hasPDF, let onOpenPDF = onOpenPDF {
            Button {
                onOpenPDF()
            } label: {
                Label("Open PDF", systemImage: "doc.text")
            }
        }

        // Download PDF (if no PDF)
        if !hasPDF, let onDownloadPDF = onDownloadPDF {
            Button {
                onDownloadPDF()
            } label: {
                Label("Download PDF", systemImage: "arrow.down.doc")
            }
        }

        // Open in Browser submenu
        if let onOpenInBrowser = onOpenInBrowser {
            Menu {
                // arXiv (if has arXiv ID)
                if data.arxivID != nil {
                    Button {
                        onOpenInBrowser(.arxiv)
                    } label: {
                        Label(BrowserDestination.arxiv.displayName, systemImage: BrowserDestination.arxiv.systemImage)
                    }
                }

                // ADS (if has bibcode)
                if data.bibcode != nil {
                    Button {
                        onOpenInBrowser(.ads)
                    } label: {
                        Label(BrowserDestination.ads.displayName, systemImage: BrowserDestination.ads.systemImage)
                    }
                }

                // DOI/Publisher (if has DOI)
                if data.doi != nil {
                    Button {
                        onOpenInBrowser(.doi)
                    } label: {
                        Label(BrowserDestination.doi.displayName, systemImage: BrowserDestination.doi.systemImage)
                    }
                }
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
        }

        // Send to E-Ink Device
        if let onSendToEInkDevice = onSendToEInkDevice {
            Button {
                onSendToEInkDevice()
            } label: {
                Label("Send to E-Ink Device", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
            }
        }

        if hasPDF || !hasPDF && onDownloadPDF != nil || onOpenInBrowser != nil || onSendToEInkDevice != nil {
            Divider()
        }
    }

    @ViewBuilder
    private var shareSection: some View {
        Menu {
            // Share Paper (system share sheet)
            if let onShare = onShare {
                Button {
                    onShare()
                } label: {
                    Label("Share Paper", systemImage: "square.and.arrow.up")
                }
            }

            // Share by Email (with PDF + BibTeX)
            if let onShareByEmail = onShareByEmail {
                Button {
                    onShareByEmail()
                } label: {
                    Label("Share by Email", systemImage: "envelope")
                }
            }

            Divider()

            // Copy Cite Key
            if let onCopyCiteKey = onCopyCiteKey {
                Button {
                    onCopyCiteKey()
                } label: {
                    Label("Copy Cite Key", systemImage: "key")
                }
            }

            // Copy BibTeX
            if let onCopyBibTeX = onCopyBibTeX {
                Button {
                    onCopyBibTeX()
                } label: {
                    Label("Copy BibTeX", systemImage: "doc.on.doc")
                }
            }

            // Copy Title
            Button {
                copyTitle()
            } label: {
                Label("Copy Title", systemImage: "doc.on.doc")
            }

            // Copy DOI
            if let doi = data.doi {
                Button {
                    copyDOI(doi)
                } label: {
                    Label("Copy DOI", systemImage: "link")
                }
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    @ViewBuilder
    private var organizationSection: some View {
        // Add to Library menu
        if !libraries.isEmpty, let onAddToLibrary = onAddToLibrary {
            Menu {
                ForEach(libraries, id: \.id) { library in
                    Button {
                        onAddToLibrary(library)
                    } label: {
                        Label(library.displayName, systemImage: "books.vertical")
                    }
                }
            } label: {
                Label("Add to Library", systemImage: "books.vertical.fill")
            }
        }

        // Add to Collection menu
        if !collections.isEmpty, let onAddToCollection = onAddToCollection {
            Menu {
                ForEach(collections, id: \.id) { collection in
                    Button {
                        onAddToCollection(collection)
                    } label: {
                        Text(collection.name)
                    }
                }
            } label: {
                Label("Add to Collection", systemImage: "folder.badge.plus")
            }
        }
    }

    @ViewBuilder
    private var exploreSection: some View {
        if onExploreReferences != nil || onExploreCitations != nil || onExploreSimilar != nil {
            Menu {
                if let onExploreReferences = onExploreReferences {
                    Button {
                        onExploreReferences()
                    } label: {
                        Label("Find References", systemImage: "doc.text.magnifyingglass")
                    }
                }

                if let onExploreCitations = onExploreCitations {
                    Button {
                        onExploreCitations()
                    } label: {
                        Label("Find Citations", systemImage: "quote.bubble")
                    }
                }

                if let onExploreSimilar = onExploreSimilar {
                    Button {
                        onExploreSimilar()
                    } label: {
                        Label("Find Similar Papers", systemImage: "rectangle.stack")
                    }
                }
            } label: {
                Label("Explore", systemImage: "sparkle.magnifyingglass")
            }
        }
    }

    @ViewBuilder
    private var inboxActionsSection: some View {
        if let onSave = onSave {
            Button {
                onSave()
            } label: {
                Label("Save to Library", systemImage: "checkmark.circle")
            }
        }

        if let onDismiss = onDismiss {
            Button {
                onDismiss()
            } label: {
                Label("Dismiss", systemImage: "xmark.circle")
            }
        }

        // Mute options
        if onMuteAuthor != nil || onMutePaper != nil {
            Menu {
                if let onMuteAuthor = onMuteAuthor {
                    Button {
                        onMuteAuthor()
                    } label: {
                        Label("Mute Author", systemImage: "person.slash")
                    }
                }

                if let onMutePaper = onMutePaper {
                    Button {
                        onMutePaper()
                    } label: {
                        Label("Mute This Paper", systemImage: "doc.badge.ellipsis")
                    }
                }
            } label: {
                Label("Mute", systemImage: "bell.slash")
            }
        }
    }

    @ViewBuilder
    private var flagContextMenu: some View {
        Menu {
            ForEach(FlagColor.allCases, id: \.self) { color in
                Button {
                    onSetFlag?(color)
                } label: {
                    Label(color.displayName, systemImage: "flag.fill")
                }
            }

            if data.flag != nil, let onClearFlag {
                Divider()
                Button {
                    onClearFlag()
                } label: {
                    Label("Clear Flag", systemImage: "flag.slash")
                }
            }
        } label: {
            Label("Flag", systemImage: data.flag != nil ? "flag.fill" : "flag")
        }
    }

    @ViewBuilder
    private var tagContextMenu: some View {
        Menu {
            if let onAddTag {
                Button {
                    onAddTag()
                } label: {
                    Label("Add Tag...", systemImage: "plus")
                }
            }

            if !data.tagDisplays.isEmpty, let onRemoveTag {
                Divider()
                ForEach(data.tagDisplays) { tag in
                    Button(role: .destructive) {
                        onRemoveTag(tag.id)
                    } label: {
                        Label("Remove: \(tag.leaf)", systemImage: "minus.circle")
                    }
                }
            }
        } label: {
            Label("Tags", systemImage: data.tagDisplays.isEmpty ? "tag" : "tag.fill")
        }
    }

    // MARK: - Actions

    private func copyTitle() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(data.title, forType: .string)
        #else
        UIPasteboard.general.string = data.title
        #endif
    }

    private func copyDOI(_ doi: String) {
        let doiURL = doi.hasPrefix("http") ? doi : "https://doi.org/\(doi)"
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(doiURL, forType: .string)
        #else
        UIPasteboard.general.string = doiURL
        #endif
    }
}

// MARK: - Preview

#Preview {
    // Create mock data for preview
    let unreadData = PublicationRowData(
        id: UUID(),
        citeKey: "Einstein1905",
        title: "On the Electrodynamics of Moving Bodies",
        authorString: "Einstein",
        year: 1905,
        abstract: "It is known that Maxwell's electrodynamics—as usually understood at the present time—when applied to moving bodies, leads to asymmetries which do not appear to be inherent in the phenomena.",
        isRead: false,
        hasDownloadedPDF: true,
        citationCount: 42,
        doi: "10.1002/andp.19053221004"
    )

    let readData = PublicationRowData(
        id: UUID(),
        citeKey: "Hawking1974",
        title: "Black hole explosions?",
        authorString: "Hawking",
        year: 1974,
        abstract: "Quantum gravitational effects are usually ignored in calculations of the formation and evolution of black holes.",
        isRead: true,
        hasDownloadedPDF: false,
        citationCount: 1500,
        doi: nil
    )

    return List {
        MailStylePublicationRow(data: unreadData)
        MailStylePublicationRow(data: readData)
    }
}

// MARK: - PublicationRowData Extension for Preview

extension PublicationRowData {
    /// Convenience initializer for previews and testing
    init(
        id: UUID,
        citeKey: String,
        title: String,
        authorString: String,
        year: Int?,
        abstract: String?,
        isRead: Bool,
        isStarred: Bool = false,
        flag: PublicationFlag? = nil,
        hasDownloadedPDF: Bool = false,
        hasOtherAttachments: Bool = false,
        citationCount: Int,
        referenceCount: Int = 0,
        doi: String?,
        arxivID: String? = nil,
        bibcode: String? = nil,
        venue: String? = nil,
        note: String? = nil,
        dateAdded: Date = Date(),
        dateModified: Date = Date(),
        primaryCategory: String? = nil,
        categories: [String] = [],
        tagDisplays: [TagDisplayData] = [],
        libraryName: String? = nil
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authorString = authorString
        self.year = year
        self.abstract = abstract
        self.isRead = isRead
        self.isStarred = isStarred
        self.flag = flag
        self.hasDownloadedPDF = hasDownloadedPDF
        self.hasOtherAttachments = hasOtherAttachments
        self.citationCount = citationCount
        self.referenceCount = referenceCount
        self.doi = doi
        self.arxivID = arxivID
        self.bibcode = bibcode
        self.venue = venue
        self.note = note
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.primaryCategory = primaryCategory
        self.categories = categories
        self.tagDisplays = tagDisplays
        self.libraryName = libraryName
    }
}
