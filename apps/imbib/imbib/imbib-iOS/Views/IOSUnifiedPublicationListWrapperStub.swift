//
//  IOSUnifiedPublicationListWrapperStub.swift
//  imbib-iOS
//
//  Temporary working replacement for the pre-Rust-migration
//  IOSUnifiedPublicationListWrapper.swift. The original file is
//  excluded from the iOS build (see project.yml) because it still
//  references deleted Core Data types. This stub implements the same
//  public shape — the `Source` enum and the view — but in terms of
//  `PublicationSource` / `PublicationRowData`, reusing the already-
//  working cross-platform `PublicationListView` from
//  PublicationManagerCore.
//
//  Scope: enough to show a working publication list for every sidebar
//  target on iOS, including the new `.citedInManuscripts` case.
//  Feature parity with the old iOS wrapper (swipe-to-triage, custom
//  multi-selection, pull-to-refresh with provider calls, per-source
//  empty-state descriptions) remains migration debt — see
//  docs/adr/ios-migration-debt.md for the tracking list.
//

import SwiftUI
import PublicationManagerCore
import OSLog

private let iosListLogger = Logger(subsystem: "com.imbib.app", category: "ios-list-stub")

struct IOSUnifiedPublicationListWrapper: View {

    // MARK: - Source type

    /// The sidebar target whose publications we display. All cases
    /// carry only value types so the view is fully decoupled from the
    /// underlying store handle.
    enum Source: Hashable {
        case library(UUID, String, isInbox: Bool)
        /// Look up the library by id and display its publications.
        /// Kept for call sites that only have an id in hand.
        case libraryByID(UUID)
        case smartSearch(UUID)
        case collection(UUID)
        case scixLibrary(UUID)
        case flagged(String?)
        case citedInManuscripts

        var id: UUID {
            switch self {
            case .library(let id, _, _),
                 .libraryByID(let id),
                 .smartSearch(let id),
                 .collection(let id),
                 .scixLibrary(let id):
                return id
            case .flagged(let color):
                return IOSUnifiedPublicationListWrapper.flaggedID(for: color)
            case .citedInManuscripts:
                return UUID(uuidString: "00000000-0000-0000-AAAA-000000000004")!
            }
        }

        @MainActor
        var navigationTitle: String {
            switch self {
            case .library(_, let name, _):
                return name
            case .libraryByID(let id):
                return RustStoreAdapter.shared.getLibrary(id: id)?.name ?? "Library"
            case .smartSearch(let id):
                return RustStoreAdapter.shared.getSmartSearch(id: id)?.name ?? "Search"
            case .collection(let id):
                let name = RustStoreAdapter.shared.listLibraries()
                    .flatMap { RustStoreAdapter.shared.listCollections(libraryId: $0.id) }
                    .first(where: { $0.id == id })?.name
                return name ?? "Collection"
            case .scixLibrary(let id):
                return RustStoreAdapter.shared.getScixLibrary(id: id)?.name ?? "SciX Library"
            case .flagged(let color):
                if let color { return "\(color.capitalized) Flagged" }
                return "Flagged"
            case .citedInManuscripts:
                return "Cited in Manuscripts"
            }
        }

        /// Map this sidebar target to a `PublicationSource` that the
        /// core data layer understands.
        @MainActor
        var publicationSource: PublicationSource {
            switch self {
            case .library(let id, _, let isInbox):
                return isInbox ? .inbox(id) : .library(id)
            case .libraryByID(let id):
                // Best-effort: treat as a regular library unless the
                // store flags it as the inbox.
                if let lib = RustStoreAdapter.shared.getLibrary(id: id), lib.isInbox {
                    return .inbox(id)
                }
                return .library(id)
            case .smartSearch(let id):
                return .smartSearch(id)
            case .collection(let id):
                return .collection(id)
            case .scixLibrary(let id):
                return .scixLibrary(id)
            case .flagged(let color):
                return .flagged(color)
            case .citedInManuscripts:
                return .citedInManuscripts
            }
        }
    }

    /// Deterministic id for `.flagged` rows — matches the macOS
    /// wrapper's mapping so saved selection state survives platform
    /// transitions.
    fileprivate static func flaggedID(for color: String?) -> UUID {
        switch color {
        case "red":    return UUID(uuidString: "F1A99ED0-0001-4000-8000-000000000000")!
        case "amber":  return UUID(uuidString: "F1A99ED0-0002-4000-8000-000000000000")!
        case "blue":   return UUID(uuidString: "F1A99ED0-0003-4000-8000-000000000000")!
        case "gray":   return UUID(uuidString: "F1A99ED0-0004-4000-8000-000000000000")!
        default:       return UUID(uuidString: "F1A99ED0-0000-4000-8000-000000000000")!
        }
    }

    // MARK: - Properties

    let source: Source
    @Binding var selectedPublicationID: UUID?

    @State private var dataSource: PaginatedDataSource
    @State private var publications: [PublicationRowData] = []
    @State private var selection: Set<UUID> = []
    @State private var dataVersion: Int = 0

    init(source: Source, selectedPublicationID: Binding<UUID?>) {
        self.source = source
        self._selectedPublicationID = selectedPublicationID
        self._dataSource = State(initialValue: PaginatedDataSource(source: source.publicationSource))
    }

    var body: some View {
        content
            .navigationTitle(source.navigationTitle)
            .task(id: source.id) {
                dataSource = PaginatedDataSource(source: source.publicationSource)
                dataSource.loadInitialPage(sort: "date_modified", ascending: false)
                publications = dataSource.rows
                dataVersion &+= 1
            }
            .onChange(of: selection) { _, newValue in
                selectedPublicationID = newValue.first
            }
    }

    @ViewBuilder
    private var content: some View {
        if publications.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptyIcon)
            } description: {
                Text(emptyDescription)
            }
        } else {
            List(publications, selection: $selection) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.body)
                        .lineLimit(2)
                    Text(row.authorString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(row.id)
            }
        }
    }

    private var emptyTitle: String {
        switch source {
        case .citedInManuscripts: return "No Cited Papers"
        case .flagged: return "No Flagged Papers"
        case .smartSearch: return "No Results"
        case .scixLibrary: return "No Papers"
        default: return "No Publications"
        }
    }

    private var emptyIcon: String {
        switch source {
        case .citedInManuscripts: return "text.book.closed"
        case .flagged: return "flag"
        case .smartSearch: return "magnifyingglass"
        default: return "tray"
        }
    }

    private var emptyDescription: String {
        switch source {
        case .citedInManuscripts:
            return "Cite a paper in imprint to see it here."
        case .flagged:
            return "Flag papers to see them here."
        case .smartSearch:
            return "Adjust the search criteria to find papers."
        default:
            return "Add publications to this source."
        }
    }
}
