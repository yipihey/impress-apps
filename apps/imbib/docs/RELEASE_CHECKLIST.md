# imbib Release Checklist

Pre-release verification steps to ensure quality before shipping. Use this checklist before merging `develop` → `main` or creating any release.

---

## Quick Checklist

Copy this for each release:

```markdown
## Release v_._._

### Tests
- [ ] `swift test` passes in PublicationManagerCore
- [ ] `xcodebuild test` passes for imbib macOS scheme
- [ ] No new compiler warnings

### Builds
- [ ] macOS build succeeds (`xcodebuild -scheme imbib build`)
- [ ] iOS build succeeds (`xcodebuild -scheme imbib-iOS build`)
- [ ] Rust xcframework builds (`./build-xcframework.sh`)

### Manual Smoke Tests
- [ ] Launch app - no crash on startup
- [ ] Open existing library
- [ ] Import BibTeX file (5+ entries)
- [ ] Import RIS file
- [ ] Search arXiv and import paper
- [ ] Search ADS and import paper (if API key configured)
- [ ] Open and read PDF
- [ ] Create highlight annotation
- [ ] Create text note
- [ ] Create collection and add papers
- [ ] Create smart collection with filter
- [ ] Export selection to BibTeX
- [ ] Keyboard navigation works (j/k, enter, escape)
- [ ] Verify CloudKit sync (if enabled)

### iOS Specific (if releasing iOS)
- [ ] iPad layout correct
- [ ] iPhone layout correct
- [ ] Share extension works
- [ ] PDF viewer works
- [ ] Annotations sync from macOS

### Version
- [ ] Version number updated in project.yml
- [ ] CHANGELOG.md updated
- [ ] Build number will auto-increment

### Final
- [ ] `git status` clean (all changes committed)
- [ ] On `develop` branch
- [ ] Ready to merge to `main`
```

---

## Detailed Test Commands

### Unit Tests

```bash
# Test the core Swift package
cd apps/imbib/PublicationManagerCore
swift test 2>&1 | tee test-output.txt

# Check for failures
grep -E "passed|failed|error" test-output.txt

# Run specific test categories
swift test --filter BibTeX
swift test --filter Search
swift test --filter PDF
swift test --filter Sync
```

### Build Verification

```bash
# Generate Xcode project
cd apps/imbib/imbib
xcodegen generate

# Build macOS
xcodebuild -scheme imbib \
  -configuration Debug \
  -destination 'platform=macOS' \
  build

# Build iOS
xcodebuild -scheme imbib-iOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build

# Build Rust xcframework (if Rust code changed)
cd crates/imbib-core
./build-xcframework.sh
```

### Run the App

```bash
# Build and run macOS app
xcodebuild -scheme imbib \
  -configuration Debug \
  -destination 'platform=macOS' \
  build

# Open built app
open ~/Library/Developer/Xcode/DerivedData/imbib-*/Build/Products/Debug/imbib.app
```

---

## Manual Testing Scenarios

### Scenario 1: Fresh Library

1. Launch app with no existing library
2. Create new library
3. Add paper via arXiv search
4. Verify paper appears in library
5. Close and reopen - paper persists

### Scenario 2: BibTeX Import

1. Find a BibTeX file with 5+ entries
2. Drag onto library or use File → Import
3. Verify all entries imported
4. Check special characters render correctly
5. Check authors parse correctly

### Scenario 3: PDF Workflow

1. Import paper with PDF URL
2. Wait for PDF download
3. Open PDF viewer
4. Navigate pages
5. Zoom in/out
6. Create highlight annotation
7. Add text note
8. Close and reopen - annotations persist

### Scenario 4: Search Sources

Test each source you support:

| Source | Test Query | Expected |
|--------|------------|----------|
| arXiv | `cosmology dark energy` | Recent papers |
| ADS | `author:Einstein` | Classic papers |
| Crossref | DOI: `10.1038/nature12373` | Single paper |
| OpenAlex | `machine learning` | Papers from OpenAlex |

### Scenario 5: Collections

1. Create new collection
2. Add papers via drag-drop
3. Remove paper from collection
4. Create smart collection with year filter
5. Verify smart collection updates automatically

### Scenario 6: Export

1. Select multiple papers
2. Export → BibTeX
3. Open exported .bib file
4. Verify it's valid BibTeX
5. Verify PDFs are referenced correctly

### Scenario 7: Keyboard Navigation

1. Focus on publication list
2. Press `j` - moves down
3. Press `k` - moves up
4. Press `Enter` - opens detail
5. Press `Escape` - closes
6. Press `⌘+F` - opens search
7. Press `⌘+N` - new collection

---

## Known Issues to Watch For

Check these areas specifically:

| Area | What to Watch | Why |
|------|---------------|-----|
| CloudKit | Sync delays | Network-dependent |
| Large libraries | Performance | 1000+ papers |
| Special characters | Unicode, LaTeX math | Parsing edge cases |
| PDF download | Timeouts | External servers |
| Memory | Large PDFs | Can spike memory use |

---

## CloudKit Verification

Before any release that touches sync or library management:

### Pre-Flight Checks

```bash
# Run the release verification script
./scripts/verify-release.sh ~/path/to/imbib.xcarchive
```

Expected output:
- ✓ CloudKit environment: Production
- ✓ CloudKit container entitlement present
- ✓ iCloud services entitlement present
- ✓ App Sandbox enabled

### Manual CloudKit Tests

- [ ] **Fresh Install Test**
  ```bash
  ./scripts/test-fresh-install.sh
  ```
  - Launch app → Should show welcome screen
  - Create library → Console shows "canonical default library ID"

- [ ] **Cross-Device Sync Test**
  - Device A: Add a paper
  - Device B: Wait 30s → Paper appears
  - Device B: Edit paper title
  - Device A: Wait 30s → Title updated

- [ ] **Library Deduplication Test**
  - Run fresh install on both devices before sync
  - Create "My Library" on both devices quickly
  - Wait for sync → Should merge to ONE library
  - Check both papers exist in merged library

### CloudKit Dashboard Checks

1. Go to [CloudKit Dashboard](https://icloud.developer.apple.com/dashboard)
2. Select **Production** environment
3. Check:
   - [ ] No failed operations in logs
   - [ ] Schema matches expected (if model changed)
   - [ ] Zone exists and has records

### Environment Verification

For the archive/TestFlight build:

```bash
# Check entitlements
codesign -d --entitlements :- ~/path/to/imbib.app 2>&1 | grep -A5 "icloud"
```

Should show:
- `com.apple.developer.icloud-container-identifiers` = `iCloud.com.imbib.app`
- `com.apple.developer.icloud-services` = `CloudKit`

**Warning Signs:**
- ⚠️ "Development" in icloud-container-environment → Wrong environment
- ⚠️ Missing icloud entitlements → Sync won't work
- ⚠️ Sandbox warning in app settings → Test build, not release

---

## Release Severity Guide

### Release Blockers (Must Fix)
- App crashes on launch
- Data loss or corruption
- Sync destroys data
- Core features completely broken

### Release Warnings (Should Fix)
- Performance degradation
- UI glitches
- Non-critical feature broken
- Confusing error messages

### Release Notes (Document)
- Minor visual issues
- Edge case bugs
- Known limitations

---

## Post-Release Monitoring

After releasing:

1. **Check crash reports** in App Store Connect (TestFlight/App Store)
2. **Monitor reviews** for recurring issues
3. **Test on fresh install** (not just upgrades)
4. **Check CloudKit dashboard** for sync errors

---

## Rollback Procedure

If critical issues found after release:

### TestFlight
1. Go to App Store Connect
2. Remove build from test group
3. Upload fixed build with new version

### App Store
1. Expedited review for critical fix
2. Or: Remove from sale temporarily

### GitHub DMG
1. Delete release
2. Create new release with fix
3. Or: Edit release to mark as pre-release

---

## Version Checklist Reference

| Version Type | When to Use |
|-------------|-------------|
| `x.x.PATCH` | Bug fixes only |
| `x.MINOR.0` | New features |
| `MAJOR.0.0` | Breaking changes |

Current version: Check `project.yml` or Info.plist
