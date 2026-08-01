//
//  RecordSidebarBuilderTests.swift
//  PublicationManagerCoreTests
//
//  The iOS sidebar is DATA (RecordSidebarBuilder) plus a dumb renderer, so
//  the interesting half is testable here, on macOS, in `swift test` — which
//  is the point: an iOS-only hand-written sidebar could only ever be checked
//  by looking at a simulator screenshot.
//
//  These assertions pin the CONFIG-DRIVEN-ness specifically: the same builder
//  fed different presets must produce different sidebars, and feeding it
//  imprint's preset must reproduce macOS's Manuscripts section (All + status
//  smart children + folder tree) without the word "manuscript" appearing
//  anywhere in the builder.
//

import XCTest
@testable import PublicationManagerCore

@MainActor
final class RecordSidebarBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func folders(_ specs: [(String, String, String?)]) -> [RecordFolder] {
        // (key, name, parentKey) — deterministic ids so assertions can name them.
        var byKey: [String: UUID] = [:]
        for (key, _, _) in specs { byKey[key] = .deterministic(from: "folder.\(key)") }
        return specs.enumerated().map { index, spec in
            RecordFolder(
                id: byKey[spec.0]!,
                name: spec.1,
                parentID: spec.2.flatMap { byKey[$0] },
                sortOrder: Int64(index))
        }
    }

    private func dataSource(
        folders: [RecordFolder] = [],
        counts: [String: Int] = [:],
        tags: [String] = [],
        available: @escaping (SidebarSectionType) -> Bool = { _ in true }
    ) -> RecordSidebarDataSource {
        RecordSidebarDataSource(
            folders: { _ in folders },
            folderCounts: { _, ids in ids.map { _ in 3 } },
            count: { scope in counts[scope.scopeKey] },
            tags: { _ in tags },
            sectionIsAvailable: available)
    }

    /// The Tags section built from `vocabulary`, under `filter`.
    private func tagSection(
        _ vocabulary: [String],
        filter: String = "",
        configuration: AppShellConfiguration = .imbib
    ) -> RecordSidebarSectionModel? {
        RecordSidebarBuilder.sections(
            configuration: configuration,
            dataSource: dataSource(tags: vocabulary),
            tagFilter: filter
        ).first { $0.section == .tags }
    }

    /// Every tag path the section renders, at every depth.
    private func tagPaths(_ section: RecordSidebarSectionModel?) -> [String] {
        func walk(_ nodes: [RecordSidebarNode]) -> [String] {
            nodes.flatMap { [$0.scope.tagPath].compactMap { $0 } + walk($0.children) }
        }
        return walk(section?.nodes ?? []).sorted()
    }

    // MARK: - Config drives the sections

    func testImprintPresetProducesItsOwnSections() {
        let sections = RecordSidebarBuilder.sections(
            configuration: .imprint, dataSource: dataSource())
        let ids = sections.map(\.section)
        XCTAssertEqual(ids, [.flagged, .citedInManuscripts, .manuscripts, .dismissed],
                       "exactly imprint's `visibleSections`, in the suite default order")
        // `.manuscripts` carries no explicit binding in the preset; it
        // resolves to the manuscript kind through the canonical table.
        XCTAssertEqual(sections.first { $0.section == .manuscripts }?.kind, .manuscript)
        XCTAssertEqual(sections.first { $0.section == .dismissed }?.kind, .manuscript)
    }

    func testImbibPresetProducesADifferentSidebarFromTheSameBuilder() {
        let sections = RecordSidebarBuilder.sections(
            configuration: .imbib, dataSource: dataSource())
        let ids = Set(sections.map(\.section))
        XCTAssertTrue(ids.contains(.inbox))
        XCTAssertTrue(ids.contains(.libraries))
        XCTAssertFalse(ids.contains(.manuscripts),
                       "imbib went publications-only; the preset must decide that, not the view")
        XCTAssertEqual(sections.first { $0.section == .flagged }?.kind, .publication)
    }

    func testFacetGatedSectionsOnlyAppearInTheirOwnShell() {
        let implore = RecordSidebarBuilder.sections(
            configuration: .implore, dataSource: dataSource())
        XCTAssertEqual(implore.map(\.section), [.figures])
        XCTAssertEqual(implore.first?.kind, .figure)

        let imprint = RecordSidebarBuilder.sections(
            configuration: .imprint, dataSource: dataSource())
        XCTAssertFalse(imprint.contains { $0.section == .figures })
    }

    func testHostContentGateIntersectsWithThePreset() {
        let sections = RecordSidebarBuilder.sections(
            configuration: .imprint,
            dataSource: dataSource(available: { $0 != .dismissed }))
        XCTAssertFalse(sections.contains { $0.section == .dismissed })
        XCTAssertTrue(sections.contains { $0.section == .manuscripts })
    }

    // MARK: - Descriptor drives the nodes

    func testPrimarySectionIsAllPlusDeclaredStatusesMinusDismissed() {
        let sections = RecordSidebarBuilder.sections(
            configuration: .imprint, dataSource: dataSource())
        guard let manuscripts = sections.first(where: { $0.section == .manuscripts }) else {
            return XCTFail("imprint must have a Manuscripts section")
        }

        XCTAssertEqual(manuscripts.nodes.first?.scope, .all(.manuscript))
        XCTAssertEqual(manuscripts.nodes.first?.title, "All Manuscripts")

        let statuses = manuscripts.nodes.compactMap { node -> String? in
            if case .status(_, let status) = node.scope { return status }
            return nil
        }
        let declared = ManuscriptRecordKind.descriptor.triage.statusValues
        XCTAssertEqual(Set(statuses), Set(declared.filter { $0 != "dismissed" }),
                       "status children ARE the descriptor's lifecycle, minus the dismissed "
                           + "status which owns the Dismissed section")
        XCTAssertFalse(statuses.contains("dismissed"))
        // The macOS smart children, by name.
        XCTAssertTrue(manuscripts.nodes.contains { $0.title == "Drafts" })
        XCTAssertTrue(manuscripts.nodes.contains { $0.title == "Submitted" })
        XCTAssertTrue(manuscripts.nodes.contains { $0.title == "Published" })
        XCTAssertTrue(manuscripts.nodes.contains { $0.title == "Archive" })
    }

    func testKindWithoutStatusesGetsNoSmartChildren() {
        // Publications declare no `statuses`, so imbib's Libraries section is
        // All + folders only — no status rows invented for it.
        let sections = RecordSidebarBuilder.sections(
            configuration: .imbib, dataSource: dataSource())
        let libraries = sections.first { $0.section == .libraries }
        let statusNodes = libraries?.nodes.filter {
            if case .status = $0.scope { return true }
            return false
        }
        XCTAssertEqual(statusNodes?.isEmpty, true)
    }

    func testFlaggedSectionOffersOneNodePerFlagColour() {
        let sections = RecordSidebarBuilder.sections(
            configuration: .imprint, dataSource: dataSource())
        let flagged = sections.first { $0.section == .flagged }
        XCTAssertEqual(flagged?.nodes.count, 4)
        XCTAssertEqual(flagged?.nodes.first?.scope, .flagged(.manuscript, "red"))
    }

    /// Every flag row must CARRY its colour. The renderer has no other way to
    /// tint it: imprint-iOS shipped four flag rows in the default tint
    /// because the node was pure title+glyph, and the fix must not be a
    /// switch statement inside the view (that is the fourth copy). Nodes that
    /// are not flag rows must carry nothing, or every folder would be tinted.
    func testEveryFlaggedNodeCarriesItsFlagColourForTheRenderer() {
        for configuration in [AppShellConfiguration.imprint, .imbib] {
            let sections = RecordSidebarBuilder.sections(
                configuration: configuration, dataSource: dataSource())
            guard let flagged = sections.first(where: { $0.section == .flagged }) else {
                XCTFail("\(configuration.appID) has no flagged section to check")
                continue
            }
            XCTAssertEqual(
                flagged.nodes.compactMap(\.flagColor), FlagColor.allCases,
                "\(configuration.appID): a flag row without a `flagColor` renders untinted")
            for node in flagged.nodes {
                let flag = try? XCTUnwrap(node.flagColor)
                XCTAssertEqual(node.title, flag?.displayName)
                // The one shared mapping is reachable from the node — this is
                // what both renderers call.
                XCTAssertNotNil(flag?.displayColor)
            }
            // Non-flag rows stay untinted.
            let others = sections.filter { $0.section != .flagged }
                .flatMap { $0.nodes.flattened(expanded: []) }
            XCTAssertTrue(
                others.allSatisfy { $0.node.flagColor == nil },
                "\(configuration.appID): a non-flag row claims a flag colour")
        }
    }

    func testDismissedSectionUsesTheKindsDismissalSemantics() {
        // Manuscripts: status-change → the node IS the dismissed status.
        let imprint = RecordSidebarBuilder.sections(
            configuration: .imprint, dataSource: dataSource())
        XCTAssertEqual(
            imprint.first { $0.section == .dismissed }?.nodes.first?.scope,
            .status(.manuscript, "dismissed"))

        // Publications: library move → an opaque section the host resolves.
        let imbib = RecordSidebarBuilder.sections(
            configuration: .imbib, dataSource: dataSource())
        XCTAssertEqual(
            imbib.first { $0.section == .dismissed }?.nodes.first?.scope,
            .section(.dismissed, .publication))
    }

    // MARK: - Folder tree

    func testFolderTreeNestsBySortOrderAndCarriesCounts() {
        let tree = folders([
            ("papers", "Papers", nil),
            ("2026", "2026", "papers"),
            ("grants", "Grants", nil),
        ])
        let sections = RecordSidebarBuilder.sections(
            configuration: .imprint, dataSource: dataSource(folders: tree))
        let manuscripts = sections.first { $0.section == .manuscripts }
        let folderNodes = manuscripts?.nodes.filter(\.isFolder) ?? []

        XCTAssertEqual(folderNodes.map(\.title), ["Papers", "Grants"], "roots only, in sort order")
        XCTAssertEqual(folderNodes.first?.children.map(\.title), ["2026"])
        XCTAssertEqual(folderNodes.first?.count, 3, "counts come from the batch kernel verb")
        XCTAssertEqual(manuscripts?.canOrganizeFolders, true,
                       "the kind's CollectionCapability.canOrganize decides, not the view")
    }

    func testFoldersAreOmittedForKindsWithNoCollectionCapability() {
        // Messages declare no collection capability.
        let nodes = RecordSidebarBuilder.folderNodes(
            kind: .message,
            descriptor: MessageRecordKind.descriptor,
            dataSource: dataSource(folders: folders([("a", "A", nil)])))
        XCTAssertTrue(nodes.isEmpty)
    }

    func testFlattenedHonoursExpansion() {
        let tree = folders([("a", "A", nil), ("b", "B", "a"), ("c", "C", "b")])
        let nodes = RecordSidebarBuilder.folderNodes(
            kind: .manuscript,
            descriptor: ManuscriptRecordKind.descriptor,
            dataSource: dataSource(folders: tree))
        XCTAssertEqual(nodes.flattened(expanded: []).map(\.node.title), ["A"])
        let a = nodes[0].id
        XCTAssertEqual(nodes.flattened(expanded: [a]).map(\.node.title), ["A", "B"])
        XCTAssertEqual(nodes.flattened(expanded: [a]).map(\.depth), [0, 1])
    }

    func testSubtreeIDsProtectAgainstReparentingIntoOwnDescendant() {
        let tree = folders([("a", "A", nil), ("b", "B", "a"), ("c", "C", "b"), ("d", "D", nil)])
        let a = tree[0]
        let forbidden = tree.subtreeIDs(of: a.id)
        XCTAssertEqual(forbidden.count, 3)
        XCTAssertFalse(forbidden.contains(tree[3].id), "an unrelated root stays a legal target")
    }

    // MARK: - Scope identity

    func testScopeKeysAreStableAndDistinct() {
        let a = RecordSidebarScope.status(.manuscript, "draft")
        let b = RecordSidebarScope.status(.manuscript, "submitted")
        XCTAssertEqual(a.scopeKey, "manuscript.status.draft")
        XCTAssertEqual(a.stableViewID, RecordSidebarScope.status(.manuscript, "draft").stableViewID)
        XCTAssertNotEqual(a.stableViewID, b.stableViewID)
        XCTAssertEqual(a.explicitStatus, "draft")
        XCTAssertEqual(RecordSidebarScope.all(.manuscript).explicitStatus, nil)
    }

    func testEffectiveRecordKindFallsBackToTheCanonicalTable() {
        // imprint binds only flagged/dismissed; `.manuscripts` resolves via
        // the impress preset's canonical section→kind table.
        XCTAssertEqual(AppShellConfiguration.imprint.recordKind(for: .manuscripts), nil)
        XCTAssertEqual(
            AppShellConfiguration.imprint.effectiveRecordKind(for: .manuscripts), .manuscript)
        // A kind the shell does not register never leaks in through the table.
        XCTAssertEqual(AppShellConfiguration.imprint.effectiveRecordKind(for: .mail), nil)
    }

    // MARK: - Tags

    func testTagVocabularyBecomesATreeWithMaterialisedAncestors() {
        let section = tagSection(["reading/queue", "reading/done", "grants"])
        XCTAssertEqual(section?.role, .tags)
        XCTAssertEqual(
            tagPaths(section), ["grants", "reading", "reading/done", "reading/queue"],
            "`reading` is materialised though nothing carries it exactly — it selects a real, "
                + "non-empty set, because matching is descendant-inclusive")
        // The LABEL is the leaf; the path is the identity.
        let reading = section?.nodes.first { $0.scope.tagPath == "reading" }
        XCTAssertEqual(reading?.title, "reading")
        XCTAssertEqual(reading?.children.map(\.title), ["done", "queue"])
    }

    func testTagSectionIsAbsentForAKindThatCannotBeTagged() {
        // Not a claim about today's descriptors: the gate is `triage.canTag`,
        // the same declaration `TriageMenu` reads.
        XCTAssertTrue(PublicationRecordKind.descriptor.triage.canTag)
        XCTAssertNil(tagSection([]), "an empty vocabulary yields no section, not an empty one")
    }

    // MARK: - Tag filtering

    func testFilterMatchesTheWholePathCaseInsensitively() {
        XCTAssertTrue(TagPathFilter.matches(path: "Reading/Queue", query: "queue"))
        XCTAssertTrue(TagPathFilter.matches(path: "reading/queue", query: "reading/qu"))
        XCTAssertFalse(TagPathFilter.matches(path: "grants", query: "queue"))
        // Unlike `TagPathMatch`, whose boundary is the separator: a filter
        // field is a substring search, and `reading-list` is a legitimate hit
        // for someone typing "reading".
        XCTAssertTrue(TagPathFilter.matches(path: "reading-list", query: "reading"))
        XCTAssertFalse(TagPathMatch.matches(recordTag: "reading-list", scopePath: "reading"))
    }

    func testBlankFilterKeepsTheWholeVocabulary() {
        XCTAssertNil(TagPathFilter.normalized("   "))
        XCTAssertEqual(TagPathFilter.retain(["a", "b"], matching: ""), ["a", "b"])
        XCTAssertEqual(TagPathFilter.retain(["a", "b"], matching: "  \n "), ["a", "b"])
    }

    func testFilteringATreeKeepsTheParentsOfMatchingLeaves() {
        let section = tagSection(
            ["reading/queue", "reading/done", "grants/nsf"], filter: "queue")
        XCTAssertEqual(
            tagPaths(section), ["reading", "reading/queue"],
            "the parent survives because a DESCENDANT matched — without it the match itself "
                + "is unreachable, which is the whole difference between filtering a tree "
                + "and filtering a list")
    }

    func testFilteringAnInteriorSegmentKeepsItsWholeSubtree() {
        let section = tagSection(["reading/queue", "reading/done", "grants/nsf"], filter: "reading")
        XCTAssertEqual(tagPaths(section), ["reading", "reading/done", "reading/queue"])
    }

    func testAFilteredTagSectionSurvivesItsOwnEmptiness() {
        // Everywhere else "no rows" means "this shell cannot serve this" and
        // the section is dropped. A Tags section that vanished on the first
        // non-matching keystroke would take the filter field with it.
        let filtered = tagSection(["reading/queue"], filter: "zzz")
        XCTAssertNotNil(filtered)
        XCTAssertEqual(filtered?.nodes.count, 0)
        // A BLANK filter is no filter, so the ordinary rule is back: an empty
        // vocabulary yields no section rather than an empty one.
        XCTAssertNil(tagSection([], filter: "   "))
        XCTAssertEqual(tagPaths(tagSection(["reading/queue"], filter: "   ")),
                       ["reading", "reading/queue"])
    }

    func testMatchCountCountsEveryRowNotJustTheRoots() {
        let section = tagSection(["reading/queue", "reading/done"], filter: "read")
        XCTAssertEqual(section?.nodes.count, 1, "one root")
        XCTAssertEqual(section?.nodes.recursiveCount, 3, "…standing for three rows")
    }

    func testEachPresetsTagsSectionBindsItsOwnKind() {
        // An empty `sectionBindings` map falls back to the canonical impress
        // table, where `.tags` is `.publication` — so a shell that forgot to
        // bind would show PAPER tags. Every preset names its own kind.
        XCTAssertEqual(tagSection(["a"], configuration: .imbib)?.kind, .publication)
        XCTAssertEqual(tagSection(["a"], configuration: .imprint)?.kind, .manuscript)
        XCTAssertEqual(tagSection(["a"], configuration: .implore)?.kind, .figure)
        XCTAssertEqual(tagSection(["a"], configuration: .impart)?.kind, .message)
        XCTAssertEqual(tagSection(["a"], configuration: .impel)?.kind, .task)
        XCTAssertEqual(tagSection(["a"], configuration: .impress)?.kind, .publication)
    }

    // MARK: - Status presentation

    func testStatusPresentationCoversTheReservedLifecycleAndDegradesGracefully() {
        XCTAssertEqual(RecordStatusPresentation.label(for: "draft"), "Drafts")
        XCTAssertEqual(RecordStatusPresentation.label(for: "in-revision"), "In Revision")
        XCTAssertEqual(RecordStatusPresentation.label(for: "peer-review"), "Peer Review")
        XCTAssertEqual(RecordStatusPresentation.systemImage(for: "archived"), "archivebox")
        XCTAssertEqual(RecordStatusPresentation.systemImage(for: "whatever"), "circle")
    }
}
