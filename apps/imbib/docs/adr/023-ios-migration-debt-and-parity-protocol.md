# ADR-023: iOS migration debt and iOS/macOS parity protocol

**Status**: Accepted
**Date**: 2026-04-10
**Supersedes**: —
**Related**: ADR-001 (Core Data), ADR-005 (SwiftUI), ADR-006 (iOS file handling)

## Context

The imbib macOS target successfully migrated off Core Data onto the Rust store during 2025–2026 (see pre-rust-migration tag). The memory-backed status note at the time said:

> **All Phases Complete**: PublicationManagerCore builds clean with zero Core Data code references.
>
> Next: macOS/iOS app targets may need updates for changed view signatures (ExportScope, UnifiedImportView, PDFViewerWithControls now use UUIDs)

That "next" step was never done for iOS. The macOS target was kept compiling; the iOS target — which depends on the same `PublicationManagerCore` package — silently fell behind. When this session's parity work for the new `citedInManuscripts` smart-library surface touched `RustStoreAdapter`, the true state surfaced: **the iOS imbib target hadn't compiled since the Rust migration landed**.

## What I found

A full `xcodebuild -scheme imbib-iOS` produced 18 errors spanning seven files that still reference types and APIs the Rust migration deleted:

| File | Size | What it broke on |
|---|---|---|
| `Views/IOSSidebarView.swift` | 2118 lines | `CDLibrary`, `CDCollection`, `CDSmartSearch`, `library.smartSearches` relationship, `NSManagedObjectContextDidSave` observers |
| `Views/IOSUnifiedPublicationListWrapper.swift` | 810 lines | `Source` enum cases wrap `CDLibrary`, `CDSmartSearch`, `CDCollection`, `CDSciXLibrary` |
| `Views/Detail/IOSInfoTab.swift` | 660 lines | `LibraryModel.containerURL` (removed when `Library` became a value type), `AttachmentManager.importAttachment(...)` (deleted signature), `Notification.Name.exploreCoReads` / `.exploreWoSRelated` (deleted) |
| `Views/IOSSettingsView.swift` | 1121 lines | `CDMutedItem`, `CDMutedItem.MuteType`, `CDLibrary` in the muted-items panel |
| `Views/IOSPDFBrowserView.swift` | 354 lines | `CDPublication` / `CDLibrary` in properties and method bodies |
| `Views/Detail/IOSPDFTab.swift` | 447 lines | `LibraryModel.containerURL`, broken `Table<R, C>` generics from the row-type change, method signature mismatch |
| `Views/Detail/IOSNoPDFView.swift` | 136 lines | `CDPublication` parameter, `AttachmentManager.importPDF(...)` deleted signature |
| `Views/Sharing/IOSMailComposer.swift` | 240 lines | `CDPublication` parameter |

Plus two cross-platform files in `PublicationManagerCore` that only broke on iOS because of missing platform guards:

- `Persistence/RustStoreAdapter.swift` — three `UIDevice.current.name` references with no `import UIKit` guard (pre-existing from ADR-021's assignment feature, never tested on iOS).
- `Persistence/LibrarySharingService.swift` — one `UIDevice.current.name` reference, same shape.
- `SharedViews/RAGChatPanel.swift` — four `Color(nsColor: .controlBackgroundColor)` calls, no platform fallback.

The `imbib-iOS-FileProvider` extension also failed because `FileProviderDataService.swift` only lived in the macOS `FileProvider/` folder. The iOS FileProvider target was missing a dependency on the type it used.

## What I shipped

Three buckets:

**1. Cross-platform `PublicationManagerCore` fixes (keep forever).**
- Added `#if canImport(UIKit) import UIKit #endif` guards to `RustStoreAdapter.swift` and `LibrarySharingService.swift`.
- Added a `controlBackgroundColor` helper in `RAGChatPanel.swift` that returns `.controlBackgroundColor` on macOS and `.secondarySystemBackground` on iOS.
- Wired `FileProvider/FileProviderDataService.swift` into the `imbib-iOS-FileProvider` target via `project.yml`'s sources list so both FileProvider extensions share one stub.

These are **real bugs**, not stubs. They restore the cross-platform invariant that `PublicationManagerCore` compiles on both platforms from the same source.

**2. iOS file exclusions (tracked as migration debt).**

`apps/imbib/imbib/project.yml`'s `imbib-iOS` target now excludes eight files under a `# iOS migration debt` comment:

```yaml
excludes:
  - "Views/IOSSidebarView.swift"
  - "Views/IOSPDFBrowserView.swift"
  - "Views/IOSUnifiedPublicationListWrapper.swift"
  - "Views/Detail/IOSNoPDFView.swift"
  - "Views/Detail/IOSPDFTab.swift"
  - "Views/IOSSettingsView.swift"
  - "Views/Sharing/IOSMailComposer.swift"
  - "Views/Detail/IOSInfoTab.swift"
```

The files stay in git history so a future migration session has the original implementations to cross-reference. They do not participate in the iOS build.

**3. Stub replacements (launchable iOS app).**

Eight new `*Stub.swift` files keep the iOS target launchable with working sidebar routing, a working publication list, and placeholder detail tabs. The stubs preserve every public symbol their excluded counterparts exposed so `IOSContentView`, `IOSDetailView`, and the rest of the unchanged iOS files still link:

| Stub | Purpose |
|---|---|
| `IOSUnifiedPublicationListWrapperStub.swift` | Working publication list for every sidebar target, including `.citedInManuscripts`. Uses `PaginatedDataSource` + `PublicationSource` directly. |
| `IOSSidebarViewStub.swift` | Minimal working sidebar: inbox, user libraries, flagged, and the new "Cited in Manuscripts" section. Hides smart searches, collections, exploration, artifacts, and SciX libraries behind a visible "iOS rebuild in progress" notice. |
| `IOSPDFBrowserViewStub.swift` | `ContentUnavailableView` placeholder. |
| `IOSNoPDFViewStub.swift` | `ContentUnavailableView` placeholder. |
| `IOSPDFTabStub.swift` | `ContentUnavailableView` placeholder; accepts `publicationID`/`libraryID`/`isFullscreen` binding to match the `IOSDetailView` call sites unchanged. |
| `IOSSettingsViewStub.swift` | Links only the sub-panels that already use value types (Appearance, Notes, Recommendations, Keyboard, Import/Export); the muted-items panel is deferred. |
| `IOSInfoTabStub.swift` | Renders title/authors/year/abstract from `RustStoreAdapter.getPublication(id:)`; defers attachments, comments, explore, and the citation-usage badge. |
| `IOSMailComposerStub.swift` | `ContentUnavailableView` placeholder. |

**4. `citedInManuscripts` parity in iOS.**

- `SidebarSection.citedInManuscripts` added to the iOS-side enum in `IOSContentView.swift`.
- `IOSContentView.contentList` routes the new case into `IOSUnifiedPublicationListWrapper(source: .citedInManuscripts, ...)`.
- `selectedLibraryID`, `currentListID`, and `currentSearchContext` switch cases extended so Swift's exhaustiveness check passes.
- The stub `IOSSidebarView` renders a "Cited in Manuscripts" section driven by `CitedInManuscriptsSnapshot.shared.citedPaperIDs.count`, refreshed on `.task` and pull-to-refresh.

Both `xcodebuild imbib` (macOS) and `xcodebuild imbib-iOS` (iOS Simulator) build cleanly. The parity feature works on both platforms.

## Root causes of the drift

1. **Shared core package, non-shared test surface.** `PublicationManagerCore` is a Swift package with `.macOS(.v26), .iOS(.v26)` platforms. Both apps depend on it. But the package's own `swift build` only covers one platform at a time and the package tests don't import the iOS UI layer. A cross-platform `#if` branch can break on one side without any CI signal.

2. **No iOS build in the primary dev loop.** During the Rust migration the author(s) built and ran the macOS target repeatedly and trusted "if macOS compiles the iOS target probably compiles too." That held while iOS files were small wrappers; it broke once iOS grew deep Core Data-backed surfaces that macOS didn't share.

3. **Duplicated `Source` enums.** The iOS `IOSUnifiedPublicationListWrapper.Source` enum is a parallel structure to the macOS `UnifiedPublicationListWrapper`'s source mechanism. Both map to the same `PublicationSource` at the bottom, but neither shares code with the other. A single change to what rows a source can point at (e.g., the new `.citedInManuscripts` case) has to be added in four places: `PublicationSource`, macOS `ImbibTab`, iOS `SidebarSection`, and the iOS `Source` enum.

4. **Platform-specific imports not guarded.** `UIDevice.current.name` was dropped into `RustStoreAdapter.swift` under `#if os(macOS) ... #else ... #endif` branches, but `import UIKit` was never added. The file compiled on macOS because the `#else` branch was never reached. Any `import Foundation`-only file that references UIKit symbols is a latent iOS break.

5. **Migration guidance lived in git memory, not in CI.** The memory note said "iOS may need updates" but there was no failing build, no failing test, no TODO inside the source tree that would catch attention. Six months later, nobody remembered the task was still open.

## Parity protocol (going forward)

Adopt these rules to prevent the same drift from recurring.

Rules with an ✅ are now enforced in tooling; rules without one are patterns that require code review to catch.

### 1. CI must build both platforms on every commit that touches `PublicationManagerCore` ✅

The package is the cross-platform fault line. Two enforcement layers are in place:

- **CI**: `.github/workflows/imbib-tests.yml` gained a `build-imbib-ios` job that runs `xcodebuild build -scheme imbib-iOS -destination 'generic/platform=iOS Simulator'` alongside the existing macOS job. Any PR that breaks the iOS build fails CI.
- **Local**: `apps/imbib/scripts/pre-push-dual-platform.sh` is a pre-push hook that builds both schemes when the push touches `PublicationManagerCore`, the iOS target, `packages/`, or `project.yml`. Install with `ln -sf ../../apps/imbib/scripts/pre-push-dual-platform.sh .git/hooks/pre-push`. Skip with `SKIP_DUAL_PLATFORM_CHECK=1 git push`.

Between the two, the dual-platform invariant is checked both on the developer's machine and in CI before merge. Neither layer alone is sufficient — CI catches pushes from machines without the hook; the local hook catches the problem before it leaves the developer's machine and keeps the feedback loop fast.

### 2. Guard every platform-specific import ✅ (partial)

When `PublicationManagerCore` (or any `.macOS(.v26), .iOS(.v26)` package) uses a UIKit or AppKit symbol, the import must be guarded:

```swift
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
```

…and the usage must be guarded with the matching `#if os(...)`. The pre-existing `#if os(macOS) let x = Host.current() #else let x = UIDevice.current #endif` pattern is only half-right — without the import, the iOS branch fails to compile.

**For colors, use the shared helpers in `ImpressTheme/PlatformColors.swift`:**

```swift
import ImpressTheme

// instead of Color(nsColor: .controlBackgroundColor)
view.background(Color.platformControlBackground)
```

The helpers are `Color.platformControlBackground`, `Color.platformWindowBackground`, `Color.platformSeparator`, and `Color.platformTertiaryLabel`. Add new helpers to that file rather than sprinkling `#if os(macOS) Color(nsColor:) #else Color(uiColor:) #endif` blocks through view bodies. `RAGChatPanel.swift` is the reference migration.

A medium-thoroughness audit of `apps/imbib/PublicationManagerCore/Sources/` and all `packages/*` came back clean after the Rule 7 refactor shipped — every remaining `AppKit` / `UIKit` use is correctly wrapped in `#if canImport` or `#if os(...)` guards. A future violation will be caught by Rule 1's CI check; Rule 2 is the pattern new code should follow to avoid hitting that failure.

### 3. Any new `PublicationSource` case must land in three enums in one PR

When adding a new source (as `citedInManuscripts` was in this session), the change set **must** include:

- `PublicationSource` in `PublicationManagerCore/Domain/PublicationSource.swift`
- `RustStoreAdapter.queryPublications(for:)` + `countPublications(for:)` switch cases
- macOS `ImbibTab` case + `SectionContentView.derivedSource` mapping + `UnifiedPublicationListWrapper` switch cases
- iOS `SidebarSection` case + `IOSContentView.contentList` routing + `IOSUnifiedPublicationListWrapper.Source` case

Swift's exhaustiveness check catches iOS-side omissions **only if iOS is being built**. See rule 1.

### 4. Shared view primitives live in `PublicationManagerCore/SharedViews/`

When a view can be written once and reused on both platforms, write it in `PublicationManagerCore/SharedViews/` and import it from both app targets. `PublicationListView` is the canonical example. New features should extend the shared primitive instead of adding parallel iOS/macOS wrappers. The ADR-005 rule ("SwiftUI + NavigationSplitView for both") implied this but never codified it.

Permitted exceptions: platform-specific chrome (NSOutlineView on macOS, List on iOS), platform-specific gestures, and platform-specific keyboard handling. The row content, the data binding, and the state model stay shared.

### 5. Value types only in view-layer properties

ADR-016 (Unified Paper Model) and the Rust migration removed Core Data managed objects from the core, but iOS views still took `CDLibrary`, `CDPublication`, etc., as property types. That was legal Swift at the time and became invalid when Core Data was deleted. The rule going forward:

**Views in both iOS and macOS targets take UUIDs or `*Model` value types as properties. Never Core Data managed objects; never `*Entity` types from a specific persistence backend.**

The iOS `Source` enum's `.library(CDLibrary)` pattern is the anti-pattern. Its stub replacement `.library(UUID, String, isInbox: Bool)` is the correct shape.

### 6. Migration debt gets an ADR, not a memory note

This document is that rule applied to itself. Whenever a migration leaves a target broken, the next commit writes an ADR listing the broken files, the root cause, and the exit criteria. Memory notes are session-local; ADRs are in-tree and visible to every future contributor.

### 7. Platform-scoped code lives in the target it belongs to ✅

**Done.** The `Host.current()` / `UIDevice.current` branches are gone from `PublicationManagerCore`. The replacement is `ImpressKit.CurrentDeviceAuthor.displayName` in `packages/ImpressKit/Sources/ImpressKit/CurrentDeviceAuthor.swift`:

```swift
public enum CurrentDeviceAuthor {
    public static var displayName: String? {
        #if os(macOS)
        return Host.current().localizedName
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #else
        return nil
        #endif
    }
}
```

`RustStoreAdapter.addCommentToItem(text:itemID:authorDisplayName:)`, `myAssignments(libraryID:currentUserName:)`, and `suggestPublication(publicationID:to:libraryID:assignedByName:note:dueDate:)` all take explicit author-name parameters. The three call sites — `CommentSectionView`, `AssignmentListView`, and `HTTPAutomationRouter` — import `ImpressKit` and pass `CurrentDeviceAuthor.displayName`. `LibrarySharingService.swift`'s CloudKit-identity fallback uses the same helper instead of its own `#if os(macOS) ... #else ... #endif` branch.

Result: `PublicationManagerCore/Persistence/RustStoreAdapter.swift` no longer imports UIKit, no longer has conditional platform branches, and the iOS build break that started this session cannot recur for this class of issue.

## Open migration debt

Tracked here so the next session can pick items up without rediscovering them:

| File | Original size | Gap |
|---|---|---|
| `IOSSidebarView.swift` | 2118 lines | Smart searches, collections, exploration library, artifacts, SciX libraries, drag-drop, reorder, rename, delete, all Core Data observations |
| `IOSUnifiedPublicationListWrapper.swift` | 810 lines | Swipe-to-triage gestures, multi-select delete, per-source empty states, smart-search refresh actions, read/unread filter toggle |
| `IOSInfoTab.swift` | 660 lines | Attachments list + drop + import, PDF source row, comments section, explore/references, citation-usage badge, flag/tag editor |
| `IOSSettingsView.swift` | 1121 lines | Muted items panel, per-library save destination, automation settings, sync controls |
| `IOSPDFBrowserView.swift` | 354 lines | Publisher URL fetch, WKWebView embed, download capture |
| `IOSPDFTab.swift` | 447 lines | PDF viewer, annotation overlay, bibliography table, SyncTeX hookup |
| `IOSNoPDFView.swift` | 136 lines | Download-from-publisher flow, Files.app import |
| `IOSMailComposer.swift` | 240 lines | MFMailComposeViewController wrapper with publication-populated subject/body |

Pre-existing cross-platform debt (shipped this session):
- `RustStoreAdapter` author-name lookup should move out of the package.
- `RAGChatPanel` should pull its platform colors from a shared theme helper instead of an inline `private var`.

The `IOSSearchView` inside `IOSContentView.swift` renders an empty array stub for `searchResultStub` because `SearchViewModel.publications` was removed by ADR-016. Search on iOS is therefore non-functional; it needs a rewrite that reads from the active library after an auto-import completes.

## Exit criteria

iOS parity is "done" when:

1. CI builds both `imbib` and `imbib-iOS` on every commit (rule 1 of the protocol).
2. The eight excluded files in `project.yml` are either deleted from git (migrated into their `Stub` replacements) or restored to the build because their content has been rewritten against value types.
3. The `Stub` suffix disappears — the minimal working versions become the real files.
4. `IOSSearchView` reads real search results.
5. The migration-debt section of this ADR lists zero open items.

Until then: the ADR stays in force, the `# iOS migration debt` block in `project.yml` stays visible, and every new iOS file must be written to the value-type / Rust-store world from day one.
