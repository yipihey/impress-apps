#if os(macOS)
// Chassis file — macOS-only. Plan wave 6, W3 (L8 leaf 4).
//
//  LayoutOutlineNode.swift
//  PublicationManagerCore
//
//  A selected sidebar row, spelled as `impress_layout_service::OutlineNode`.
//
//  This file MAPS and decides nothing. Which query a row is, whether it is a
//  legacy route, and which verbs retarget the list pane are Rust's answers
//  (`outline_row_verbs_json`); this is the spelling of the question, and the
//  reverse spelling a scoped legacy pane uses to rebuild the route it hosts.
//  The wire shapes are `outline.rs`'s serde forms: `#[serde(tag = "node",
//  rename_all = "kebab-case")]`, record scopes tagged on `"scope"`.
//

import Foundation

@MainActor
enum LayoutOutlineNode {

    // MARK: Section names

    /// The `SidebarSectionType` CASE name — the spelling `named_queries` and
    /// `MATERIALIZE_FIRST` use. Not the raw value: `.manuscripts` is stored
    /// as `"journal"`, and Rust calls it `manuscripts`.
    static func sectionName(_ section: SidebarSectionType) -> String {
        String(describing: section)
    }

    static func section(named name: String) -> SidebarSectionType? {
        SidebarSectionType.allCases.first { sectionName($0) == name }
    }

    // MARK: Tab → node

    /// The node a tab is, plus the parameter ids its section query needs.
    ///
    /// `tagKind` is the record kind the shell binds Tags to (implore: figure,
    /// impel: task), which is a shell fact the tab does not carry.
    static func node(
        for tab: ImbibTab, shell: AppShellConfiguration, dismissedLibraryID: UUID?
    ) -> (node: LayoutJSONValue, bindings: [String: String]) {
        func obj(_ fields: [String: LayoutJSONValue]) -> LayoutJSONValue { .object(fields) }
        func section(_ s: SidebarSectionType) -> LayoutJSONValue {
            obj(["node": .string("section"), "section": .string(sectionName(s))])
        }
        func id(_ node: String, _ uuid: UUID) -> LayoutJSONValue {
            obj(["node": .string(node), "id": .string(uuid.uuidString.lowercased())])
        }
        func record(_ kind: RecordKindID, _ scope: [String: LayoutJSONValue]) -> LayoutJSONValue {
            obj(["node": .string("record"), "kind": .string(kind.rawValue), "scope": .object(scope)])
        }
        func smart(_ uuid: UUID, _ s: SidebarSectionType) -> LayoutJSONValue {
            obj([
                "node": .string("smart-search"), "id": .string(uuid.uuidString.lowercased()),
                "section": .string(sectionName(s)),
            ])
        }

        switch tab {
        case .inbox:
            var bindings: [String: String] = [:]
            if let inbox = InboxManager.shared.inboxLibrary {
                bindings["library"] = inbox.id.uuidString.lowercased()
            }
            return (section(.inbox), bindings)
        case .library(let uuid):
            return (id("library", uuid), [:])
        case .sharedLibrary(let uuid):
            return (id("shared-library", uuid), [:])
        case .scixLibrary(let uuid):
            return (id("scix-library", uuid), [:])
        case .searchForm(let form):
            return (obj(["node": .string("search-form"), "form": .string(form.rawValue)]), [:])
        case .exploration(let uuid):
            return (smart(uuid, .exploration), [:])
        case .collection(let uuid), .explorationCollection(let uuid), .inboxCollection(let uuid):
            return (id("collection", uuid), [:])
        case .inboxFeed(let uuid):
            return (smart(uuid, .inbox), [:])
        case .libraryFeed(let uuid):
            return (smart(uuid, .libraries), [:])
        case .flagged(let color):
            let kind = shell.recordKind(for: .flagged) ?? .publication
            return (record(kind, flaggedScope(color)), [:])
        case .customSurface(let surface):
            return (obj(["node": .string("custom-surface"), "id": .string(surface)]), [:])
        case .watchedFolder(_, let tagPath):
            // A watched folder's papers ARE its provenance tag (ADR-0023).
            return (record(.publication, ["scope": .string("tag"), "path": .string(tagPath)]), [:])
        case .tag(let path):
            let kind = shell.recordKind(for: .tags) ?? .publication
            return (record(kind, ["scope": .string("tag"), "path": .string(path)]), [:])
        case .allArtifacts:
            return (section(.artifacts), [:])
        case .artifactType(let type):
            return (obj(["node": .string("artifact-type"), "type": .string(type)]), [:])
        case .dismissed:
            var bindings: [String: String] = [:]
            if let libraryID = dismissedLibraryID {
                bindings["dismissed_library"] = libraryID.uuidString.lowercased()
            }
            return (section(.dismissed), bindings)
        case .citedInManuscripts:
            return (section(.citedInManuscripts), [:])
        case .recent:
            return (obj(["node": .string("recent")]), [:])
        case .reviewQueue:
            return (section(.reviewQueue), [:])
        case .record(let route):
            return (recordNode(route), [:])
        case .recordDetail(let kind, let recordID):
            return (
                obj([
                    "node": .string("record-detail"), "kind": .string(kind.rawValue),
                    "id": .string(recordID),
                ]), [:]
            )
        case .auxiliary(let route):
            return (obj(["node": .string("auxiliary"), "route": .string(route.rawValue)]), [:])
        // The feed form carries the feed being edited or the library a new
        // feed is for (review PH-M1), so the pane it routes to opens THAT
        // form and not generic feed creation.
        case .addFeed:
            return (obj(["node": .string("feed-form")]), [:])
        case .editFeed(let feed):
            return (obj(["node": .string("feed-form"), "feed": .string(feed.uuidString.lowercased())]), [:])
        case .addLibraryFeed(let library):
            return (
                obj(["node": .string("feed-form"), "library": .string(library.uuidString.lowercased())]),
                [:]
            )
        }
    }

    private static func flaggedScope(_ color: String?) -> [String: LayoutJSONValue] {
        var scope: [String: LayoutJSONValue] = ["scope": .string("flagged")]
        scope["color"] = color.map { .string($0) } ?? .null
        return scope
    }

    private static func recordNode(_ route: RecordRoute) -> LayoutJSONValue {
        let scope: [String: LayoutJSONValue]
        switch route.scope {
        case .all:
            scope = ["scope": .string("all")]
        case .status(_, let status):
            scope = ["scope": .string("status"), "status": .string(status)]
        case .folder(_, let folder):
            scope = ["scope": .string("folder"), "id": .string(folder.uuidString.lowercased())]
        case .flagged(_, let color):
            scope = flaggedScope(color)
        case .tag(_, let path):
            scope = ["scope": .string("tag"), "path": .string(path)]
        case .section(let section, _):
            return .object(["node": .string("section"), "section": .string(sectionName(section))])
        case .host(_, let key):
            scope = ["scope": .string("host"), "key": .string(key)]
        }
        return .object([
            "node": .string("record"), "kind": .string(route.kind.rawValue),
            "scope": .object(scope),
        ])
    }

    // MARK: Node → tab (the scoped legacy pane)

    /// The route a scoped legacy pane hosts, from the node its `view_state`
    /// carries. nil for a node that names no route (the pane then says so).
    static func tab(from node: LayoutJSONValue) -> ImbibTab? {
        guard let fields = node.objectValue, let tag = fields["node"]?.stringValue else {
            return nil
        }
        func uuid(_ key: String) -> UUID? { fields[key]?.stringValue.flatMap(UUID.init(uuidString:)) }
        switch tag {
        case "section":
            guard let name = fields["section"]?.stringValue, let section = section(named: name)
            else { return nil }
            switch section {
            case .inbox: return .inbox
            case .artifacts: return .allArtifacts
            case .dismissed: return .dismissed
            case .citedInManuscripts: return .citedInManuscripts
            case .reviewQueue: return .reviewQueue
            default:
                // A section that is not itself a route (sharedWithMe,
                // scixLibraries, tags): its header is not selectable, so no
                // row led here — the pane says so rather than guess a route.
                return nil
            }
        case "library": return uuid("id").map { .library($0) }
        case "collection": return uuid("id").map { .collection($0) }
        case "shared-library": return uuid("id").map { .sharedLibrary($0) }
        case "scix-library": return uuid("id").map { .scixLibrary($0) }
        case "search-form":
            return fields["form"]?.stringValue.flatMap(SearchFormType.init(rawValue:)).map {
                .searchForm($0)
            }
        case "feed-form":
            if let feed = uuid("feed") { return .editFeed(feed) }
            if let library = uuid("library") { return .addLibraryFeed(library) }
            return .addFeed
        case "recent": return .recent
        case "artifact-type": return fields["type"]?.stringValue.map { .artifactType($0) }
        case "custom-surface": return fields["id"]?.stringValue.map { .customSurface($0) }
        case "smart-search":
            guard let id = uuid("id") else { return nil }
            switch fields["section"]?.stringValue {
            case "inbox": return .inboxFeed(id)
            case "exploration": return .exploration(id)
            default: return .libraryFeed(id)
            }
        case "record-detail":
            guard let kind = fields["kind"]?.stringValue, let id = fields["id"]?.stringValue
            else { return nil }
            return .recordDetail(RecordKindID(kind), id)
        case "auxiliary":
            return fields["route"]?.stringValue.flatMap(AuxiliaryRoute.init(rawValue:)).map {
                .auxiliary($0)
            }
        case "record":
            guard let kindRaw = fields["kind"]?.stringValue,
                  let scope = fields["scope"]?.objectValue,
                  let scopeTag = scope["scope"]?.stringValue
            else { return nil }
            let kind = RecordKindID(kindRaw)
            switch scopeTag {
            case "all": return .record(.all(kind))
            case "status": return scope["status"]?.stringValue.map { .record(.status(kind, $0)) }
            case "folder":
                return scope["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map {
                    .record(.folder(kind, $0))
                }
            case "flagged": return .record(.flagged(kind, scope["color"]?.stringValue))
            case "tag":
                guard let path = scope["path"]?.stringValue else { return nil }
                return kind == .publication ? .tag(path: path) : .record(RecordRoute(kind: kind, scope: .tag(kind, path)))
            case "host":
                return scope["key"]?.stringValue.map {
                    .record(RecordRoute(kind: kind, scope: .host(kind, key: $0)))
                }
            default: return nil
            }
        default:
            return nil
        }
    }
}
#endif
