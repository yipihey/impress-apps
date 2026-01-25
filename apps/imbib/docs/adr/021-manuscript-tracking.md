# ADR-021: Manuscript Tracking and Citation Management

**Status:** Proposed
**Date:** 2026-01-19
**Authors:** Tom Abel, Claude

## Context

imbib serves as a bibliography manager for researchers, handling paper collection, PDF storage, annotation, and BibTeX export. Users have expressed need for tighter integration between their reference library and their active writing projects.

The current workflow involves friction:
- Bibliography files (.bib) must be manually synchronized between imbib and writing environments
- No connection between papers a researcher reads and papers they cite
- Manuscript versions, referee reports, and revision history are managed outside imbib
- No visibility into which papers inform which manuscripts

An earlier proposal (ADR-001-manuscript-management) suggested full project management with SwiftGit2, iCloud folder sync, and Overleaf integration. After analysis, we propose a simpler approach that leverages imbib's existing architecture.

## Decision

### 1. Manuscripts are Publications with Extended Metadata

Manuscripts are not a separate entity. They are `CDPublication` entries representing papers the user is authoring, with additional metadata stored in `rawFields`.

```swift
// Manuscript metadata stored in rawFields JSON
extension CDPublication {
    var manuscriptStatus: ManuscriptStatus? {
        get { ManuscriptStatus(rawValue: fields["_manuscript_status"] ?? "") }
        set {
            var f = fields
            f["_manuscript_status"] = newValue?.rawValue
            fields = f
        }
    }

    var submissionVenue: String? {
        get { fields["_submission_venue"] }
        set { ... }
    }

    var revisionNumber: Int {
        get { Int(fields["_revision_number"] ?? "0") ?? 0 }
        set { ... }
    }

    var manuscriptNotes: String? {
        get { fields["_manuscript_notes"] }
        set { ... }
    }

    var citedPublicationIDs: [UUID] {
        // Stored as JSON array of UUID strings
        get { ... }
        set { ... }
    }
}

public enum ManuscriptStatus: String, Codable, CaseIterable {
    case drafting = "drafting"
    case submitted = "submitted"
    case underReview = "under_review"
    case revision = "revision"
    case accepted = "accepted"
    case published = "published"
    case rejected = "rejected"

    var displayName: String { ... }
    var systemImage: String { ... }
}
```

**Rationale:**
- No Core Data schema changes required
- Manuscripts appear alongside read papers in the library
- Can be organized into collections, tagged, and searched uniformly
- CloudKit syncs metadata automatically
- BibTeX export preserves manuscript fields in comments

### 2. Version Tracking via Attachment Tags

Manuscript versions are tracked using the existing `CDLinkedFile` + `CDAttachmentTag` system.

```swift
// Predefined attachment tag categories for manuscripts
extension CDAttachmentTag {
    static let manuscriptTagPrefix = "manuscript:"

    static func submissionTag(version: Int) -> String {
        "\(manuscriptTagPrefix)submission-v\(version)"
    }

    static func revisionTag(round: Int) -> String {
        "\(manuscriptTagPrefix)revision-r\(round)"
    }

    static let refereeReport = "\(manuscriptTagPrefix)referee-report"
    static let responseLetter = "\(manuscriptTagPrefix)response-letter"
    static let finalAccepted = "\(manuscriptTagPrefix)final-accepted"
    static let published = "\(manuscriptTagPrefix)published"
}
```

**Version workflow:**
1. User attaches initial draft → auto-tagged "submission-v1"
2. After revision, attach new PDF → auto-tagged "revision-r1"
3. Referee reports attached → tagged "referee-report"
4. Response letter → tagged "response-letter"
5. Final version → tagged "final-accepted" or "published"

**File naming convention:**
- `Smith_2026_DeepLearning_submission_v1.pdf`
- `Smith_2026_DeepLearning_revision_r1.pdf`
- `Smith_2026_DeepLearning_referee_r1.pdf`
- `Smith_2026_DeepLearning_published.pdf`

### 3. Citation Linking (Manuscript ↔ Library)

Each manuscript stores references to cited publications, enabling citation intelligence.

```swift
// Citation relationship stored in rawFields as UUID array
extension CDPublication {
    /// Publications this manuscript cites (for manuscripts)
    var citedPublications: [CDPublication] {
        let context = PersistenceController.shared.viewContext
        return citedPublicationIDs.compactMap { id in
            // Fetch by ID
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            return try? context.fetch(request).first
        }
    }

    /// Manuscripts that cite this publication (for library papers)
    var citedByManuscripts: [CDPublication] {
        // Reverse lookup: find manuscripts where citedPublicationIDs contains self.id
        ...
    }
}
```

**Citation intelligence enabled:**
- "Papers cited in [Manuscript]" smart collection
- "Papers read but never cited" discovery
- "Papers cited in multiple manuscripts" analysis
- Suggest citations from library based on topic overlap

### 4. Bibliography Export Modes

Each manuscript can be configured for how its .bib file is managed:

```swift
public enum BibliographyMode: String, Codable {
    case manual
    // User manages .bib externally; imbib can import changes

    case autoGenerated
    // imbib generates .bib from cited publications automatically

    case watched
    // imbib watches an external .bib and imports new entries
}

extension CDPublication {
    var bibliographyMode: BibliographyMode {
        get { BibliographyMode(rawValue: fields["_bib_mode"] ?? "manual") ?? .manual }
        set { ... }
    }

    var externalBibPath: String? {
        // Path to external .bib file (for watched mode)
        get { fields["_external_bib_path"] }
        set { ... }
    }
}
```

**Export workflow:**
1. User marks papers as "cited" in manuscript
2. imbib generates `references.bib` containing only cited papers
3. User drags to Overleaf or copies to project folder
4. On changes, imbib re-exports (manual trigger or file system watcher)

### 5. Manuscript Collections

A "Manuscripts" smart collection automatically shows all papers with `manuscriptStatus != nil`.

```swift
// Built-in smart collection predicate
let manuscriptsCollection = CDSmartSearch()
manuscriptsCollection.name = "My Manuscripts"
manuscriptsCollection.query = "_manuscript_status:*"
manuscriptsCollection.icon = "doc.text"
```

Additional automatic groupings:
- "Active" (drafting, submitted, under_review, revision)
- "Completed" (accepted, published)
- By venue (ApJ, MNRAS, etc.)
- By year

### 6. Import from External Projects

Instead of live git sync, support one-time imports:

```swift
public actor ManuscriptImporter {
    /// Import from Overleaf download (.zip)
    public func importFromOverleaf(zipURL: URL) async throws -> CDPublication

    /// Import from local folder (detect .bib, .tex, .pdf)
    public func importFromFolder(folderURL: URL) async throws -> CDPublication

    /// Parse .aux file to find cited keys
    public func parseCitations(auxURL: URL) -> [String]
}
```

**Import workflow:**
1. Download project from Overleaf as .zip
2. imbib extracts and creates manuscript entry
3. Parses .aux to identify cited papers
4. Links citations to library (or creates stubs for missing)
5. Imports referee reports if present

### 7. No Git Integration

**Rejected: SwiftGit2**

After analysis, we explicitly reject git integration because:
- 2MB binary size increase
- Complex iOS integration (no system git)
- libgit2 maintenance burden
- Overleaf's git has quirks requiring workarounds
- Conflicts with imbib's CloudKit sync model

Instead:
- **Export** bibliography to any folder (user syncs via git/Dropbox/iCloud)
- **Import** from downloaded archives or local folders
- **Watch** external .bib files for changes (file system events)

This keeps imbib focused on bibliography management rather than becoming a project IDE.

## Consequences

### Enabled Capabilities

**Citation Intelligence**
- Papers read but never cited (rediscover relevant work)
- Papers cited repeatedly across manuscripts
- Citation suggestions based on library content
- Citation overlap between manuscripts

**Manuscript Timeline**
- Version history with PDF snapshots
- Referee report organization with annotations
- Status progression tracking
- Deadline awareness (if user enters dates)

**Unified Search**
- Single query searches: library papers, manuscript metadata, cited refs
- Filter by manuscript status, venue, year

**Recommendation Integration (ADR-020)**
- Manuscripts inform author/venue affinities
- Citations are strong positive signals
- "More like papers I cited" suggestions

### Constraints

**No Live Sync**
- User must manually export .bib files
- Changes in Overleaf require re-import
- This is intentional: sync conflicts are avoided

**Metadata in rawFields**
- No dedicated Core Data attributes
- Slightly more complex queries
- But: no migrations, CloudKit-friendly

**Citation Links are IDs**
- Broken if cited paper is deleted
- Need cleanup routine for orphaned references

### Migration Path

1. Existing imbib users: no changes required
2. "New Manuscript" appears in add menu
3. Can convert any existing publication to manuscript
4. Citations can be added incrementally

## Implementation Phases

### Phase 1: Core Model Extensions
- `ManuscriptStatus` enum
- `CDPublication` extension for manuscript metadata
- Manuscript tag constants for `CDAttachmentTag`
- "Manuscripts" smart collection

### Phase 2: Citation Linking
- UI to mark papers as "cited in [manuscript]"
- Cited publications view in manuscript detail
- Reverse lookup: "manuscripts citing this paper"
- Citation count per manuscript

### Phase 3: Bibliography Export
- Generate .bib from cited publications
- Export with drag-and-drop or save dialog
- Include custom preamble/postamble
- Optional: watch mode with FSEvents

### Phase 4: Import & Parse
- Import from .zip (Overleaf download)
- Import from local folder
- Parse .aux for cited keys
- Create stubs for unknown citations

### Phase 5: UI Polish
- Manuscript status badges in list view
- Version timeline in detail view
- Submission tracking dashboard
- Deadline reminders (notifications)

## Alternatives Considered

### Full Git Integration (SwiftGit2)

As proposed in the original ADR-001.

**Rejected because:**
- Significant binary size increase
- iOS has no system git; full libgit2 needed
- Overleaf git has documented quirks
- Conflicts with CloudKit for file sync
- Turns imbib into a project manager, not bibliography manager

### Manuscripts as Separate Entity

A `CDManuscript` Core Data entity with its own relationships.

**Rejected because:**
- Duplicates infrastructure (tags, collections, search)
- Fragments the mental model
- Requires Core Data migration
- Loses the insight that manuscripts are part of your corpus

### Overleaf API Integration

Direct Overleaf API instead of git.

**Rejected because:**
- API is limited and undocumented
- OAuth complexity for iOS
- Dependency on third-party service stability
- Git export is Overleaf's official integration point

## Related Documents

- ADR-016: Unified Paper Model (manuscripts as publications)
- ADR-020: Recommendation Engine (citations as signals)
- ADR-004: Human-readable PDF names (version naming)

## Open Questions

1. **Should citations be a Core Data relationship?**
   Currently: stored as UUID array in rawFields.
   Alternative: `CDCitation` join entity with `manuscript` and `citedPaper`.
   Trade-off: Cleaner queries vs. schema change and migration.

2. **File system watching for .bib changes?**
   FSEvents on macOS, polling on iOS.
   Or: require manual re-import (simpler, more predictable).

3. **Deadline tracking?**
   Store `submissionDeadline: Date?` in rawFields?
   Enable notifications for upcoming deadlines?

4. **arXiv submission packaging?**
   Generate .tar.gz with .bbl and required files?
   Validate against arXiv requirements?
