// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). A settings preset IS
// the app's declarative preferences identity, exactly as `AppShellConfiguration`
// is its sidebar identity. An iOS shell that cannot read it has to re-encode
// the same list by hand — which, until this file, it did not: imprint-iOS
// shipped NO settings, because the list existed only as a macOS `TabView` body.
//
//  AppSettingsConfiguration.swift
//  ImpressChassis (lifted out of PublicationManagerCore by C5)
//
//  Stage 6 phase 1 (ADR-0021 descriptor/factory split, applied to settings).
//
//  WHY A SIBLING FILE, not `AppShellConfiguration.swift`:
//
//  1. Concurrency of authorship. `AppShellConfiguration.swift` is under active
//     edit by the record-descriptor work; a settings preset appended to it
//     would collide for no structural gain.
//  2. Different consumers. The shell preset is read by the sidebar builder,
//     `SectionContentView` and the shell parity tests; a settings preset is
//     read by exactly two renderers. Fusing them would make every settings
//     change a diff on the file the whole chassis depends on.
//  3. Extraction shape. ADR-0021 D5 deferred the package split but wanted the
//     folder boundary honest in advance, so that `Chassis/Settings/` would be
//     a clean folder move — which it would not have been if the preset lived
//     in the shell file. **C5 (2026-07-30) collected on that**: this file and
//     `SettingsSectionDescriptor.swift` are the move, and they are now in
//     `packages/ImpressChassis`. `SettingsSectionRegistry.swift` did NOT come
//     with them — it reads `AppearanceMode` from PMC's theme layer — which is
//     the descriptor/factory split of D3 turning into a package boundary
//     rather than a new one being invented.
//
//  They stay siblings, not strangers: `AppShellConfiguration` is still in PMC
//  (it names `SidebarSectionType`), both remain `appID`-keyed presets, and
//  `AppSettingsConfigurationTests` asserts every settings preset's `appID`
//  matches a shell preset's — across the package boundary now — so the two
//  cannot drift into disagreeing about which apps exist.
//

import Foundation

// MARK: - Builtin section ids

public extension SettingsSectionID {
    /// Generic chrome — the chassis ships the pane (`SettingsSectionRegistry.builtin`).
    static let appearance = SettingsSectionID("appearance")
    static let spotlight = SettingsSectionID("spotlight")

    /// Ids the chassis NAMES but does not implement: every app has a "General",
    /// and naming it here is what lets two apps' General panes sort to the same
    /// place and carry the same accessibility identifier while their CONTENT
    /// stays app-owned. (`SettingsSectionRegistry.builtin` has no factory for
    /// these; a preset that lists one without registering a factory fails
    /// `unresolvedSections`.)
    static let general = SettingsSectionID("general")
    static let editor = SettingsSectionID("editor")
    static let account = SettingsSectionID("account")
    static let automation = SettingsSectionID("automation")
    static let git = SettingsSectionID("git")
    static let ai = SettingsSectionID("ai")
    static let aiTasks = SettingsSectionID("aiTasks")
    static let documents = SettingsSectionID("documents")
    static let export = SettingsSectionID("export")
    /// imprint's citations pane. The id is `imbib` and NOT `citations` because
    /// the shipped accessibility identifier is `settings.tabs.imbib` — the tab
    /// is labelled "Citations" and identified as "imbib", and both are frozen.
    static let imbib = SettingsSectionID("imbib")
    static let latex = SettingsSectionID("latex")

    // MARK: Phase-2 ids

    /// Ids added in Stage 6 phase 2 for imbib, implore, impel and impart.
    ///
    /// Every one of these whose pane shipped with an accessibility identifier
    /// takes its rawValue FROM that identifier, not from the Swift case name
    /// that happened to sit next to it. `shortcuts` is the instructive one:
    /// imbib's enum case is `keyboardShortcuts` and its tab is labelled
    /// "Keyboard Shortcuts", but the shipped identifier is
    /// `settings.tabs.shortcuts` — so the id is `shortcuts`, exactly as
    /// imprint's Citations tab is `imbib`. The identifier is the frozen artifact;
    /// the case name never was.
    ///
    /// `keyboard` and `shortcuts` are BOTH here, and are not a duplication:
    /// implore shipped `settings.tabs.keyboard`, imbib shipped
    /// `settings.tabs.shortcuts`, and unifying them would silently rename one
    /// app's identifier.
    static let viewing = SettingsSectionID("viewing")
    static let flagsAndTags = SettingsSectionID("flagsAndTags")
    static let notes = SettingsSectionID("notes")
    static let sources = SettingsSectionID("sources")
    static let pdf = SettingsSectionID("pdf")
    static let enrichment = SettingsSectionID("enrichment")
    static let searchAI = SettingsSectionID("searchAI")
    static let inbox = SettingsSectionID("inbox")
    static let recommendations = SettingsSectionID("recommendations")
    static let sync = SettingsSectionID("sync")
    static let eink = SettingsSectionID("eink")
    static let importExport = SettingsSectionID("importExport")
    /// imbib's keyboard pane. Id from the shipped `settings.tabs.shortcuts`.
    static let shortcuts = SettingsSectionID("shortcuts")
    static let advanced = SettingsSectionID("advanced")

    /// iOS-shaped imbib sections. Each is a genuine platform difference, not an
    /// unfinished port — see `AppSettingsConfiguration.imbib`.
    static let backup = SettingsSectionID("backup")
    static let pdfStorage = SettingsSectionID("pdfStorage")
    static let smartSearch = SettingsSectionID("smartSearch")
    static let console = SettingsSectionID("console")
    static let help = SettingsSectionID("help")
    static let about = SettingsSectionID("about")

    /// implore.
    static let rendering = SettingsSectionID("rendering")
    static let colormaps = SettingsSectionID("colormaps")
    /// implore's and impart's keyboard pane. Id from `settings.tabs.keyboard`.
    static let keyboard = SettingsSectionID("keyboard")

    /// impel.
    static let counsel = SettingsSectionID("counsel")

    /// impart. Plural, and NOT `account`: imprint's `account` pane is iCloud and
    /// store sync, impart's `accounts` pane is email accounts. Same word, two
    /// subjects — one id for both would sort and identify them as one pane.
    static let accounts = SettingsSectionID("accounts")
}

// MARK: - Builtin groups

public extension SettingsSectionGroup {
    /// imbib's six shipped sidebar headers, verbatim from the `List` in
    /// `apps/imbib/imbib/imbib/Views/Settings/SettingsView.swift`.
    static let general = SettingsSectionGroup("General")
    static let content = SettingsSectionGroup("Content")
    static let inboxAndFeeds = SettingsSectionGroup("Inbox & Feeds")
    static let syncAndBackup = SettingsSectionGroup("Sync & Backup")
    static let importAndExport = SettingsSectionGroup("Import & Export")
    static let system = SettingsSectionGroup("System")

    /// Bands that exist only on iOS, so they never affect the macOS sidebar.
    /// imbib-iOS's hand-written screen used these three headers verbatim.
    static let developer = SettingsSectionGroup("Developer")
    static let helpAndSupport = SettingsSectionGroup("Help & Support")
    static let about = SettingsSectionGroup("About")
}

// MARK: - Configuration

/// The ordered settings surface of one app.
public struct AppSettingsConfiguration: Sendable {

    /// Matches `AppShellConfiguration.appID`.
    public let appID: String

    /// Every section this app declares, in display order.
    ///
    /// Sorted by `SettingsSectionDescriptor.order` at init (stably — ties keep
    /// declaration order), so the ordering is DATA and not "whatever sequence
    /// the literal happened to be typed in".
    public let sections: [SettingsSectionDescriptor]

    /// The section a renderer lands on when it has to pick one (the macOS
    /// `TabView`'s first tab; the iOS list has no selection). nil ⇒ the first
    /// available section.
    public let defaultSection: SettingsSectionID?

    public init(
        appID: String,
        sections: [SettingsSectionDescriptor],
        defaultSection: SettingsSectionID? = nil
    ) {
        self.appID = appID
        // `sorted(by:)` is not documented stable; enumerate-then-sort is.
        self.sections = sections.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
        self.defaultSection = defaultSection
    }

    /// The sections a renderer on `platform` should show.
    ///
    /// `capabilities` defaults to `SettingsHostCapabilities.default(for:)`; a
    /// caller overrides it to model a host that lacks something (and tests use
    /// it to drive the filter both ways from either platform).
    public func sections(
        on platform: SettingsPlatform,
        capabilities: Set<SettingsRequirement>? = nil
    ) -> [SettingsSectionDescriptor] {
        let capabilities = capabilities ?? SettingsHostCapabilities.default(for: platform)
        return sections.filter {
            $0.availability.isSatisfied(on: platform, capabilities: capabilities)
        }
    }

    /// The sections to show on the platform this binary is running on.
    public var currentPlatformSections: [SettingsSectionDescriptor] {
        sections(on: .current)
    }

    public subscript(id: SettingsSectionID) -> SettingsSectionDescriptor? {
        sections.first { $0.id == id }
    }

    // MARK: Grouping

    /// One band of a grouped settings sidebar.
    public struct SectionGroup: Identifiable, Sendable {
        /// nil ⇒ the leading ungrouped run (rendered without a header).
        public let group: SettingsSectionGroup?
        public let sections: [SettingsSectionDescriptor]

        public var id: String { group?.rawValue ?? "" }
        public var title: String? { group?.title }
    }

    /// The sections a `platform` shows, banded by `descriptor.group`.
    ///
    /// Bands appear in the order their FIRST member appears — group order is
    /// derived, never declared, so a group cannot sort against its own contents
    /// (see `SettingsSectionGroup`). Runs are built by walking the already-sorted
    /// section list and starting a new band whenever the group changes, which
    /// means a group whose members are NOT contiguous renders as two bands with
    /// the same header. That is a declaration bug, not a rendering one, and
    /// `testEveryGroupedPresetKeepsItsGroupsContiguous` is what fails when it
    /// happens rather than a user noticing a duplicated header.
    public func sectionGroups(
        on platform: SettingsPlatform,
        capabilities: Set<SettingsRequirement>? = nil
    ) -> [SectionGroup] {
        var bands: [SectionGroup] = []
        for descriptor in sections(on: platform, capabilities: capabilities) {
            if let last = bands.last, last.group == descriptor.group {
                bands[bands.count - 1] = SectionGroup(
                    group: last.group, sections: last.sections + [descriptor])
            } else {
                bands.append(SectionGroup(group: descriptor.group, sections: [descriptor]))
            }
        }
        return bands
    }

    // MARK: Presets

    /// imprint: the 13 macOS tabs, in the order the `TabView` shipped them.
    ///
    /// This is a REFRAME, not a redesign. Every title, every SF Symbol, every
    /// accessibility identifier and the order are the ones
    /// `apps/imprint/macOS/Views/SettingsView.swift` had before Stage 6; the
    /// macOS Settings scene must remain visually equivalent, and
    /// `AppSettingsConfigurationTests.testImprintPresetIsTheFrozenThirteenTabInventory`
    /// is the oracle that says so.
    ///
    /// Five of the thirteen reach iOS, which is five more than before. The
    /// eight that do not each name WHY in `availability` — a capability the
    /// platform lacks, or (for `ai`/`aiTasks`/`export`) an implementation that
    /// lives in imprint's macOS target and has no iOS counterpart yet. Neither
    /// is a permanent verdict: an iOS pane appears the day someone registers a
    /// factory and widens the descriptor's `platforms`, with no renderer edit.
    public static let imprint = AppSettingsConfiguration(
        appID: "imprint",
        sections: [
            SettingsSectionDescriptor(
                id: .appearance,
                title: "Appearance",
                systemImage: "paintbrush",
                subtitle: "Light, dark, or follow the system",
                availability: .everywhere,
                order: 10),
            SettingsSectionDescriptor(
                id: .general,
                title: "General",
                systemImage: "gear",
                subtitle: "Editing, live preview, backups",
                availability: .everywhere,
                order: 20),
            SettingsSectionDescriptor(
                id: .editor,
                title: "Editor",
                systemImage: "doc.text",
                subtitle: "Font, display, modal editing",
                availability: .everywhere,
                order: 30),
            // AI: `AIAssistantService` + the keychain API-key editor live in
            // imprint's macOS target. No iOS provider surface exists yet.
            SettingsSectionDescriptor(
                id: .ai,
                title: "AI",
                systemImage: "sparkles",
                subtitle: "Provider, API keys, inline completion",
                availability: .macOSOnly(),
                order: 40),
            // AI Tasks: same reason — the task catalog is
            // `AIContextMenuService`, a macOS-target service.
            SettingsSectionDescriptor(
                id: .aiTasks,
                title: "AI Tasks",
                systemImage: "sparkles.rectangle.stack",
                subtitle: "Enable, disable and edit author tasks",
                availability: .macOSOnly(),
                order: 50),
            SettingsSectionDescriptor(
                id: .imbib,
                title: "Citations",
                systemImage: "books.vertical",
                subtitle: "imbib connection and bibliography",
                availability: .macOSOnly(requiring: [.siblingAppDiscovery]),
                order: 60),
            SettingsSectionDescriptor(
                id: .latex,
                title: "LaTeX",
                systemImage: "function",
                subtitle: "TeX distribution, engine, compilation",
                availability: .macOSOnly(requiring: [.localToolchain]),
                order: 70),
            SettingsSectionDescriptor(
                id: .documents,
                title: "Documents",
                systemImage: "doc.badge.gearshape",
                subtitle: "Validation, backups, format version",
                availability: .everywhere,
                order: 80),
            // Export: `TemplateService` / `TemplateBrowserView` are macOS.
            SettingsSectionDescriptor(
                id: .export,
                title: "Export",
                systemImage: "square.and.arrow.up",
                subtitle: "Default format, templates, bibliography",
                availability: .macOSOnly(),
                order: 90),
            SettingsSectionDescriptor(
                id: .account,
                title: "Account",
                systemImage: "person.circle",
                subtitle: "iCloud and store sync",
                availability: .everywhere,
                order: 100),
            SettingsSectionDescriptor(
                id: .automation,
                title: "Automation",
                systemImage: "gearshape.2",
                subtitle: "HTTP API and MCP integration",
                availability: .macOSOnly(requiring: [.httpAutomation]),
                order: 110),
            SettingsSectionDescriptor(
                id: .git,
                title: "Git",
                systemImage: "arrow.triangle.branch",
                subtitle: "Repository status and sync defaults",
                availability: .macOSOnly(requiring: [.localToolchain]),
                order: 120),
            SettingsSectionDescriptor(
                id: .spotlight,
                title: "Spotlight",
                systemImage: "magnifyingglass",
                subtitle: "System search index",
                availability: .macOSOnly(requiring: [.spotlightIndex]),
                order: 130),
        ],
        defaultSection: .appearance)

    // MARK: - Phase 2

    /// imbib: the 16 macOS sidebar panes in six groups, plus the five sections
    /// that are genuinely iOS-shaped.
    ///
    /// **imbib is the app that made the group a descriptor field.** Its macOS
    /// Settings scene is a `NavigationSplitView` source list, not a `TabView` —
    /// sixteen panes under "General", "Content", "Inbox & Feeds", "Sync &
    /// Backup", "Import & Export", "System" — so it renders through
    /// `MacSettingsSidebarSceneContent`. Titles, SF Symbols, group headers,
    /// order, and the `helpText` tooltips (now `subtitle`) are verbatim from the
    /// `SettingsTab` enum this preset replaces;
    /// `SettingsSurfaceContractTests.testImbibPresetIsTheFrozenSixteenPaneSidebar`
    /// is the oracle.
    ///
    /// **imbib registers OVER the chassis `appearance` builtin, and that is the
    /// interesting negative result of phase 2.** The builtin is a three-way
    /// System/Light/Dark picker over `appearanceMode` — right for imprint,
    /// implore and impart, whose appearance UI was exactly that. imbib's
    /// Appearance pane is an 834-line THEME EDITOR (named themes, accent colors,
    /// font scale, mail-style density) over `ThemeSettingsStore`, and the
    /// `appearanceMode` key is one row inside it. Replacing it with the builtin
    /// would delete real UI, so imbib layers its own factory over the same id —
    /// the documented `SettingsSectionRegistry.register` semantics, used for the
    /// reason they exist. A shared builtin is only shared where it is the SAME
    /// pane; "every app has an Appearance tab" is not the same claim.
    ///
    /// Eleven of the sixteen reach iOS. The five that do not, and the five iOS
    /// sections that have no Mac tab, each state why in `availability` — imbib is
    /// the only app in the suite that had a hand-written iOS settings screen, so
    /// unlike imprint the differences here are real prior art rather than
    /// absences.
    public static let imbib = AppSettingsConfiguration(
        appID: "imbib",
        sections: [
            // ── General ──────────────────────────────────────────────────────
            // NSOpenPanel for the library location and an in-process HTTP server
            // for the browser extension: both macOS-only, and the pane is mostly
            // those two things.
            SettingsSectionDescriptor(
                id: .general,
                title: "General",
                systemImage: "gear",
                subtitle: "App preferences",
                availability: .macOSOnly(requiring: [.httpAutomation]),
                group: .general,
                order: 10),
            SettingsSectionDescriptor(
                id: .appearance,
                title: "Appearance",
                systemImage: "paintbrush",
                subtitle: "Theme and colors",
                availability: .everywhere,
                group: .general,
                order: 20),
            SettingsSectionDescriptor(
                id: .viewing,
                title: "Viewing",
                systemImage: "eye",
                subtitle: "List display options",
                availability: .everywhere,
                group: .general,
                order: 30),

            // ── Content ──────────────────────────────────────────────────────
            // Flags & Tags: the pane is a macOS colour-well grid over
            // NSColorPanel; iOS never had it.
            SettingsSectionDescriptor(
                id: .flagsAndTags,
                title: "Flags & Tags",
                systemImage: "flag",
                subtitle: "Flag colors and tag display settings",
                availability: .macOSOnly(),
                group: .content,
                order: 40),
            SettingsSectionDescriptor(
                id: .notes,
                title: "Notes",
                systemImage: "note.text",
                subtitle: "Note editor settings",
                availability: .everywhere,
                group: .content,
                order: 50),
            SettingsSectionDescriptor(
                id: .pdf,
                title: "PDF",
                systemImage: "doc.richtext",
                subtitle: "PDF download settings",
                availability: .everywhere,
                group: .content,
                order: 60),
            SettingsSectionDescriptor(
                id: .sources,
                title: "Sources",
                systemImage: "globe",
                subtitle: "API keys for online sources",
                availability: .everywhere,
                group: .content,
                order: 70),
            SettingsSectionDescriptor(
                id: .enrichment,
                title: "Enrichment",
                systemImage: "arrow.triangle.2.circlepath",
                subtitle: "Citation sources and metadata enrichment",
                availability: .everywhere,
                group: .content,
                order: 80),
            // Search & AI: the embedding-provider surface talks to a local
            // model server / on-disk index, which sandboxed iOS has no path to.
            SettingsSectionDescriptor(
                id: .searchAI,
                title: "Search & AI",
                systemImage: "brain",
                subtitle: "Embedding provider and search intelligence",
                availability: .macOSOnly(requiring: [.localToolchain]),
                group: .content,
                order: 90),

            // ── Inbox & Feeds ────────────────────────────────────────────────
            SettingsSectionDescriptor(
                id: .inbox,
                title: "Inbox",
                systemImage: "tray",
                subtitle: "Feed subscriptions and mute rules",
                availability: .everywhere,
                group: .inboxAndFeeds,
                order: 100),
            SettingsSectionDescriptor(
                id: .recommendations,
                title: "Recommendations",
                systemImage: "sparkles",
                subtitle: "Configure transparent recommendation engine",
                availability: .everywhere,
                group: .inboxAndFeeds,
                order: 110),

            // ── Sync & Backup ────────────────────────────────────────────────
            SettingsSectionDescriptor(
                id: .sync,
                title: "Sync",
                systemImage: "icloud",
                subtitle: "iCloud sync settings",
                availability: .everywhere,
                group: .syncAndBackup,
                order: 120),
            // E-Ink: reMarkable / Supernote / Kindle Scribe transfer over SSH
            // and USB. No such surface on iOS.
            SettingsSectionDescriptor(
                id: .eink,
                title: "E-Ink Devices",
                systemImage: "rectangle.portrait",
                subtitle: "reMarkable, Supernote, and Kindle Scribe integration",
                availability: .macOSOnly(requiring: [.localToolchain]),
                group: .syncAndBackup,
                order: 130),

            // ── Import & Export ──────────────────────────────────────────────
            SettingsSectionDescriptor(
                id: .importExport,
                title: "Import & Export",
                systemImage: "arrow.up.arrow.down",
                subtitle: "File format options",
                availability: .everywhere,
                group: .importAndExport,
                order: 140),

            // ── System ───────────────────────────────────────────────────────
            SettingsSectionDescriptor(
                id: .shortcuts,
                title: "Keyboard Shortcuts",
                systemImage: "keyboard",
                subtitle: "Customize keyboard shortcuts",
                availability: .everywhere,
                group: .system,
                order: 150),
            SettingsSectionDescriptor(
                id: .advanced,
                title: "Advanced",
                systemImage: "gearshape.2",
                subtitle: "Developer tools and advanced settings",
                availability: .everywhere,
                group: .system,
                order: 160),

            // ── iOS-only sections ────────────────────────────────────────────
            //
            // INTERLEAVED into the macOS orders, not appended after them, and the
            // reason is `sectionGroups`: bands are contiguous runs of the SORTED,
            // FILTERED section list, so a group must stay contiguous on BOTH
            // platforms independently. Parking `backup` at order 210 in
            // "Sync & Backup" would have rendered that header twice on iOS —
            // once for `sync` at 120, again for `backup` after `advanced` at 160.
            // Giving it 125 instead makes the iOS band [sync, backup] and the
            // macOS band [sync, eink], each contiguous, from one declaration.
            // `testEveryGroupedPresetKeepsItsGroupsContiguous` checks both
            // platforms for exactly this.

            // Smart Search: on macOS the result-limit stepper is a SECTION of the
            // General pane, and iOS does not get that pane (NSOpenPanel, HTTP
            // server). Rather than port a whole pane for one control, iOS keeps
            // its own row. A separate id and not `searchAI`, because it is a
            // different control over a different store.
            SettingsSectionDescriptor(
                id: .smartSearch,
                title: "Search",
                systemImage: "magnifyingglass",
                subtitle: "Smart search result limit",
                availability: SettingsSectionAvailability(platforms: [.iOS]),
                group: .general,
                order: 35),
            // PDF Storage: the on-demand PDF model IS the iOS File Provider
            // extension. Its key is even namespaced `sync.ios.syncAllPDFs`. On the
            // Mac every PDF is simply a file on disk, so the pane would have
            // nothing to say.
            SettingsSectionDescriptor(
                id: .pdfStorage,
                title: "PDF Storage",
                systemImage: "externaldrive.fill.badge.icloud",
                subtitle: "On-demand downloads and local storage",
                availability: SettingsSectionAvailability(platforms: [.iOS]),
                group: .content,
                order: 65),
            // Library Backup: macOS nests `BackupSettingsSection` INSIDE its Sync
            // pane; iOS hoists it to a sibling row, because on a phone the Sync
            // pane is already a full screen and a backup is what you reach for
            // when sync is the problem. Promoting it on macOS too would add a
            // SEVENTEENTH pane, which visual equivalence forbids — so this is the
            // one place the platforms deliberately differ in STRUCTURE rather
            // than in content, and now they differ by declaration.
            SettingsSectionDescriptor(
                id: .backup,
                title: "Library Backup",
                systemImage: "arrow.down.doc",
                subtitle: "Snapshot and restore the whole library",
                availability: SettingsSectionAvailability(platforms: [.iOS]),
                group: .syncAndBackup,
                order: 125),
            // Automation: macOS carries automation as two SECTIONS of its General
            // pane (URL scheme toggle, HTTP server + port). iOS has always had a
            // standalone pane instead, because the phone version is a different
            // subject — Tailscale/local network addresses and a bearer token to
            // copy, none of which a Mac needs. Giving iOS `automation` while
            // macOS keeps those rows inside `general` is therefore not a gap: it
            // is two honest surfaces over one capability.
            SettingsSectionDescriptor(
                id: .automation,
                title: "Automation API",
                systemImage: "terminal",
                subtitle: "Network access and bearer token",
                availability: SettingsSectionAvailability(platforms: [.iOS]),
                group: .system,
                order: 155),
            // Console: macOS opens the log console as its own ⌘⇧C WINDOW. iOS has
            // no secondary windows, so the console is reached from settings.
            SettingsSectionDescriptor(
                id: .console,
                title: "Console",
                systemImage: "terminal",
                subtitle: "Live log output",
                availability: SettingsSectionAvailability(platforms: [.iOS]),
                group: .developer,
                order: 230),
            // Help / About: macOS puts these in the Help menu and the standard
            // About window, neither of which iOS has.
            SettingsSectionDescriptor(
                id: .help,
                title: "Help",
                systemImage: "questionmark.circle",
                subtitle: "Guides, documentation and issue reporting",
                availability: SettingsSectionAvailability(platforms: [.iOS]),
                group: .helpAndSupport,
                order: 240),
            SettingsSectionDescriptor(
                id: .about,
                title: "About",
                systemImage: "info.circle",
                subtitle: "Version and build",
                availability: SettingsSectionAvailability(platforms: [.iOS]),
                group: .about,
                order: 250),
        ],
        defaultSection: .general)

    /// implore: five macOS tabs, unchanged in title, symbol, identifier, order.
    ///
    /// implore has NO iOS target, so every section is `.macOSOnly()` — the
    /// weaker "the implementation lives in the app's macOS target" claim, stated
    /// as such (see `SettingsSectionAvailability`). Spotlight additionally
    /// declares `.spotlightIndex`, which is a real capability rather than a
    /// target boundary.
    ///
    /// Spotlight is the one tab that becomes a CHASSIS BUILTIN: implore's tab
    /// body was literally `Form { SpotlightSettingsSection() }.formStyle(.grouped)`,
    /// which is `SpotlightSettingsPane` verbatim. The other four are app content
    /// (rendering, colormaps, a shortcut reference table) and register from
    /// implore.
    public static let implore = AppSettingsConfiguration(
        appID: "implore",
        sections: [
            SettingsSectionDescriptor(
                id: .general,
                title: "General",
                systemImage: "gear",
                subtitle: "Startup, modal editing, files",
                availability: .macOSOnly(),
                order: 10),
            SettingsSectionDescriptor(
                id: .rendering,
                title: "Rendering",
                systemImage: "paintbrush",
                subtitle: "Point size, antialiasing, frame rate",
                availability: .macOSOnly(),
                order: 20),
            SettingsSectionDescriptor(
                id: .colormaps,
                title: "Colormaps",
                systemImage: "paintpalette",
                subtitle: "Default colormap and colorbar",
                availability: .macOSOnly(),
                order: 30),
            SettingsSectionDescriptor(
                id: .keyboard,
                title: "Keyboard",
                systemImage: "keyboard",
                subtitle: "Shortcut reference",
                availability: .macOSOnly(),
                order: 40),
            SettingsSectionDescriptor(
                id: .spotlight,
                title: "Spotlight",
                systemImage: "magnifyingglass",
                subtitle: "System search index",
                availability: .macOSOnly(requiring: [.spotlightIndex]),
                order: 50),
        ],
        defaultSection: .general)

    /// impel: three macOS tabs.
    ///
    /// impel's Settings scene is `#if os(macOS)`-gated in `ImpelApp.swift`; there
    /// is no iOS settings surface, hence `.macOSOnly()` throughout. Counsel
    /// additionally declares `.httpAutomation` — it binds LISTENING SMTP and IMAP
    /// ports, which needs the same `com.apple.security.network.server`
    /// entitlement iOS does not grant, so the requirement is the honest one even
    /// though the protocol is not HTTP.
    ///
    /// **impel adopts no chassis builtin, and that is a finding.** It has no
    /// Appearance tab and no Spotlight tab, and phase 2 does not add them:
    /// growing an app's settings surface is a product change, not a reframe.
    /// What the migration DOES buy impel is that its three panes are now named in
    /// data, so the absence is visible instead of implicit.
    public static let impel = AppSettingsConfiguration(
        appID: "impel",
        sections: [
            SettingsSectionDescriptor(
                id: .general,
                title: "General",
                systemImage: "gear",
                subtitle: "Server URL and refresh interval",
                availability: .macOSOnly(),
                order: 10),
            SettingsSectionDescriptor(
                id: .ai,
                title: "AI",
                systemImage: "brain",
                subtitle: "Model and system prompt",
                availability: .macOSOnly(),
                order: 20),
            SettingsSectionDescriptor(
                id: .counsel,
                title: "Counsel",
                systemImage: "envelope",
                subtitle: "Mail gateway, ports, agent loop",
                availability: .macOSOnly(requiring: [.httpAutomation]),
                order: 30),
        ],
        defaultSection: .general)

    /// impart: six macOS tabs, two of which now also render on iOS.
    ///
    /// Phase 2 declared `.macOSOnly()` throughout, for a reason it wrote down:
    /// impart-iOS had its own hand-rolled settings `List` but did not link
    /// PublicationManagerCore, "so no chassis renderer can run there today …
    /// claiming `.everywhere` would describe a screen that cannot be built".
    /// **Stage 5c linked the package** (`apps/impart/project.yml`, `impart-iOS`
    /// dependencies), so that sentence expired and two rows became buildable:
    ///
    ///  * `.general` — Appearance + Default View are pure `@AppStorage` over
    ///    `appearanceMode` / `defaultViewMode`, the same two keys macOS reads.
    ///    impart-iOS's `IOSAppearanceSettingsView` was a THIRD hand-rolled clone
    ///    of `ImpressTheme.AppearanceSettingsSection` over that key; it is gone,
    ///    and the iOS pane is registered app-side against this descriptor.
    ///  * `.accounts` — the account list. On iOS it is READ-ONLY, over the
    ///    `mail-account` rows in the shared store (`MailSidebarSnapshot`),
    ///    because account creation is an IMAP/Keychain flow impart-iOS has no
    ///    path for. The old iOS pane's `+` button had an empty body; a row that
    ///    reports which accounts this device can see is the honest version.
    ///
    /// The other four stay `.macOSOnly()`, and each absence is real: `.ai` is a
    /// provider/key surface impart-iOS does not run, `.keyboard` is a shortcut
    /// reference for a hardware-keyboard-first window, and `.automation` /
    /// `.spotlight` carry capability requirements iOS never grants.
    ///
    /// Spotlight becomes the chassis builtin (impart's tab was the same
    /// `Form { SpotlightSettingsSection() }` wrapper implore's was). Automation
    /// stays impart-registered even though `ImpressAutomation` ships a shared
    /// section: impart's pane has a toggle and a port and NO `logRequests` row,
    /// so swapping in the shared section would ADD a control — a visible change
    /// to a surface that must stay equivalent. That is a phase-3 alignment, and
    /// noting it here is how it stops being invisible.
    public static let impart = AppSettingsConfiguration(
        appID: "impart",
        sections: [
            SettingsSectionDescriptor(
                id: .accounts,
                title: "Accounts",
                systemImage: "person.crop.circle",
                subtitle: "Email accounts",
                availability: .everywhere,
                order: 10),
            SettingsSectionDescriptor(
                id: .ai,
                title: "AI",
                systemImage: "brain.head.profile",
                subtitle: "Provider, keys, and privacy",
                availability: .macOSOnly(),
                order: 20),
            SettingsSectionDescriptor(
                id: .general,
                title: "General",
                systemImage: "gearshape",
                subtitle: "Appearance and default view",
                availability: .everywhere,
                order: 30),
            SettingsSectionDescriptor(
                id: .keyboard,
                title: "Keyboard",
                systemImage: "keyboard",
                subtitle: "Shortcut reference",
                availability: .macOSOnly(),
                order: 40),
            SettingsSectionDescriptor(
                id: .automation,
                title: "Automation",
                systemImage: "terminal",
                subtitle: "HTTP API",
                availability: .macOSOnly(requiring: [.httpAutomation]),
                order: 50),
            SettingsSectionDescriptor(
                id: .spotlight,
                title: "Spotlight",
                systemImage: "magnifyingglass",
                subtitle: "System search index",
                availability: .macOSOnly(requiring: [.spotlightIndex]),
                order: 60),
        ],
        defaultSection: .accounts)

    /// impress: TWO panes, one of which the chassis already owns.
    ///
    /// The unifying shell has the SMALLEST settings surface in the suite, and
    /// that is the D9 claim showing up in a second place. impress adds no
    /// feature of its own — it hosts every facet through the chassis — so it
    /// configures only what a shell genuinely has: how it looks, and its
    /// automation port.
    ///
    ///  * `.appearance` is `.everywhere` and comes from
    ///    `SettingsSectionRegistry.builtin`. impress registers no factory for
    ///    it, which is the implore/impart precedent for Spotlight: an app that
    ///    hand-wrote a pane identical to the builtin would be re-forking the
    ///    thing the builtin exists to share. It is `.everywhere` because the
    ///    builtin pane is plain SwiftUI over `@AppStorage("appearanceMode")` and
    ///    genuinely renders on both platforms — impress-iOS shows exactly this
    ///    one row.
    ///  * `.automation` carries `.httpAutomation`, so it is macOS-only for a
    ///    CAPABILITY reason rather than a policy one: iOS never grants
    ///    `com.apple.security.network.server`.
    ///
    /// What is deliberately ABSENT, because declaring it would describe a
    /// surface impress does not run:
    ///  * `.spotlight` — impress installs no CoreSpotlight coordinator. The
    ///    other four macOS apps each install one in their `init()`; adding the
    ///    tab without the coordinator would configure an index nothing writes.
    ///  * `.ai`, `.keyboard`, `.accounts`, `.sync`, `.backup`, `.advanced` —
    ///    features impress hosts but does not own. Their configuration lives in
    ///    the app that owns the feature; a duplicate here would be a second
    ///    writer to one set of keys.
    public static let impress = AppSettingsConfiguration(
        appID: "impress",
        sections: [
            SettingsSectionDescriptor(
                id: .appearance,
                title: "Appearance",
                systemImage: "paintbrush",
                subtitle: "Light, dark, or system",
                availability: .everywhere,
                order: 10),
            SettingsSectionDescriptor(
                id: .automation,
                title: "Automation",
                systemImage: "terminal",
                subtitle: "HTTP API",
                availability: .macOSOnly(requiring: [.httpAutomation]),
                order: 20),
        ],
        defaultSection: .appearance)

    /// Every preset the chassis ships, for tests that must not silently skip a
    /// new app. `AppSettingsConfigurationTests` iterates this rather than naming
    /// presets one at a time, which is what caught phase 2's presets needing the
    /// same appID/shell-preset agreement phase 1's did.
    public static let allPresets: [AppSettingsConfiguration] = [
        .imprint, .imbib, .implore, .impel, .impart, .impress,
    ]
}
