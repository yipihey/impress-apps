# imbib Release Guide

Complete runbook for releasing imbib to TestFlight, App Store, and GitHub.

## Quick Reference

```bash
# TestFlight (iOS + macOS beta)
./scripts/release.sh testflight v1.2.0

# TestFlight (iOS only)
./scripts/release.sh testflight v1.2.0 --ios-only

# TestFlight (macOS only)
./scripts/release.sh testflight v1.2.0 --macos-only

# Local DMG build (macOS direct download)
./scripts/release.sh dmg v1.2.0

# GitHub release (triggers CI to build DMG)
./scripts/release.sh github v1.2.0

# Check release status and credentials
./scripts/release.sh status

# First-time credential setup
./scripts/release.sh setup
```

## Release Channels

imbib has three distribution channels:

| Channel | Platforms | Use Case | Distribution |
|---------|-----------|----------|--------------|
| **TestFlight** | iOS + macOS | Beta testing | App Store Connect |
| **App Store** | iOS + macOS | Production | App Store |
| **GitHub DMG** | macOS only | Direct download | GitHub Releases |

### When to Use Each Channel

```
┌─────────────────────────────────────────────────────────────────────┐
│                       RELEASE DECISION TREE                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Is this a beta/preview release?                                    │
│  ├─ YES → TestFlight (./scripts/release.sh testflight)              │
│  │        - Testers get automatic updates                           │
│  │        - 90-day build expiration                                 │
│  │        - Crash reports in App Store Connect                      │
│  │                                                                   │
│  └─ NO → Is this for App Store?                                     │
│          ├─ YES → First upload to TestFlight, then submit           │
│          │        from App Store Connect                            │
│          │                                                           │
│          └─ NO → GitHub DMG (./scripts/release.sh github)           │
│                  - Direct download for power users                  │
│                  - No Apple review required                         │
│                  - macOS only                                        │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Workflows

### TestFlight Release (Recommended for Beta)

TestFlight is the primary channel for beta releases. It uploads both iOS and macOS apps to App Store Connect.

**Prerequisites:**
- Clean working tree (commit or stash changes)
- App Store Connect API credentials configured
- Valid distribution certificates in Keychain

**Steps:**

1. **Ensure clean state:**
   ```bash
   git status  # Should be clean
   ./scripts/release.sh status  # Check credentials
   ```

2. **Run the release:**
   ```bash
   ./scripts/release.sh testflight v1.2.0
   ```

3. **Wait for processing:**
   - Build uploads to App Store Connect
   - Apple processes the build (15-30 minutes)
   - You'll receive an email when processing completes

4. **Distribute to testers:**
   - Go to [App Store Connect](https://appstoreconnect.apple.com/apps)
   - Select imbib → TestFlight
   - Add the build to your testing group(s)
   - Testers receive notification via TestFlight app

**Options:**
```bash
# iOS only (skip macOS)
./scripts/release.sh testflight v1.2.0 --ios-only

# macOS only (skip iOS)
./scripts/release.sh testflight v1.2.0 --macos-only

# Skip UI tests (use with caution)
./scripts/release.sh testflight v1.2.0 --skip-tests
```

### App Store Release

App Store releases go through TestFlight first, then are submitted for Apple review.

**Steps:**

1. **Upload to TestFlight:**
   ```bash
   ./scripts/release.sh testflight v1.2.0
   ```

2. **Test on TestFlight:**
   - Verify the build works correctly
   - Test on multiple devices/macOS versions
   - Fix any issues and re-upload if needed

3. **Submit for review:**
   - Go to [App Store Connect](https://appstoreconnect.apple.com/apps)
   - Select imbib → App Store
   - Select the TestFlight build
   - Fill in "What's New" release notes
   - Submit for review

4. **Wait for review:**
   - Initial reviews: 24-48 hours typically
   - Updates: Usually faster
   - You'll receive email notifications

### GitHub DMG Release

GitHub releases provide direct downloads for users who prefer not to use the App Store.

**Option A: Automated (via GitHub Actions)**

```bash
./scripts/release.sh github v1.2.0
```

This creates a tag and pushes it, triggering GitHub Actions to:
- Build the app (both Intel + Apple Silicon)
- Sign with Developer ID certificate
- Notarize with Apple
- Create and upload DMG to GitHub Releases

**Option B: Local Build**

For testing or when GitHub Actions isn't available:

```bash
./scripts/release.sh dmg v1.2.0
```

This builds a notarized DMG locally (Apple Silicon only).

To upload manually:
```bash
gh release create v1.2.0 \
  "build/imbib-v1.2.0-macOS-arm64.dmg" \
  --title "v1.2.0" \
  --notes "Release notes here"
```

## Versioning

### Version Format

```
v{major}.{minor}.{patch}
 │  │      │       │
 │  │      │       └── Bug fixes, minor changes
 │  │      └────────── New features, non-breaking
 │  └───────────────── Breaking changes
 └──────────────────── Prefix (required)
```

Examples:
- `v1.0.0` - Major release
- `v1.1.0` - New feature
- `v1.1.1` - Bug fix

### Build Number

Build numbers are automatically generated:

```
{commit_count}.{YYMMDDHHMM}
      │              │
      │              └── Timestamp (year/month/day/hour/minute)
      └─────────────── Total git commits
```

Example: `1234.2501291430` = Commit #1234, built 2025-01-29 at 14:30

### Tag Format

| Channel | Tag Format | Example |
|---------|------------|---------|
| GitHub DMG | `imbib-v{version}` | `imbib-v1.2.0` |
| TestFlight | No tag required | - |
| App Store | No tag required | - |

The `imbib-` prefix is required for GitHub releases to trigger the correct workflow.

## Pre-Release Checklist

Before any release:

- [ ] All tests pass: `swift test` in PublicationManagerCore
- [ ] App builds successfully: `xcodebuild -scheme imbib build`
- [ ] CHANGELOG.md updated with changes
- [ ] Version number updated if needed
- [ ] No uncommitted changes: `git status`

For App Store releases:
- [ ] Screenshots up to date (if UI changed)
- [ ] App Store description accurate
- [ ] Privacy policy URL valid
- [ ] All required metadata filled in

## Troubleshooting

### Missing Credentials

```
Missing credentials: TEAM_ID ASC_KEY_ID
```

**Solution:** Run setup to configure credentials:
```bash
./scripts/release.sh setup
```

### API Key File Not Found

```
API key file not found: ~/.appstoreconnect/private_keys/AuthKey_XXXXX.p8
```

**Solution:**
1. Download the .p8 file from App Store Connect
2. Save it to the correct location:
   ```bash
   mkdir -p ~/.appstoreconnect/private_keys
   mv ~/Downloads/AuthKey_XXXXX.p8 ~/.appstoreconnect/private_keys/
   ```

### Certificate Not Found

```
Error: No signing certificate found
```

**Solution:**
1. Open Keychain Access
2. Verify you have "Developer ID Application" (for DMG) or "Apple Distribution" (for App Store)
3. If missing, download from Apple Developer portal or create in Xcode

### Notarization Failed

```
Error: Notarization failed
```

**Solution:**
1. Check notarization log:
   ```bash
   xcrun notarytool log <submission-id> \
     --apple-id "$APPLE_ID" \
     --password "$APPLE_APP_PASSWORD" \
     --team-id "$TEAM_ID"
   ```
2. Common issues:
   - Hardened Runtime not enabled
   - Missing code signature
   - Unsigned nested bundles

### Build Already Exists

```
Error: A build with this version already exists
```

**Solution:** Build numbers are auto-generated with timestamps, so this shouldn't happen. If it does:
1. Wait a minute (timestamp-based)
2. Or increment the version number

### UI Tests Failed

```
UI Tests Failed - Release Aborted
```

**Solution:**
1. Review the test output
2. Fix failing tests
3. Or skip tests if you're confident (not recommended):
   ```bash
   ./scripts/release.sh testflight v1.2.0 --skip-tests
   ```

## Credential Reference

Credentials are stored in macOS Keychain under these services:

| Keychain Service | Account | Used For |
|-----------------|---------|----------|
| `imbib-release` | `team-id` | All releases |
| `imbib-release` | `apple-id` | DMG notarization |
| `imbib-release` | `app-password` | DMG notarization |
| `imbib-testflight` | `asc-key-id` | TestFlight uploads |
| `imbib-testflight` | `asc-issuer-id` | TestFlight uploads |

To view stored credentials:
```bash
security find-generic-password -s "imbib-release" -a "team-id" -w
```

To delete and reconfigure:
```bash
security delete-generic-password -s "imbib-release" -a "team-id"
./scripts/release.sh setup
```

## Related Documentation

- [RELEASE_SETUP.md](RELEASE_SETUP.md) - Credential setup details
- [CHANGELOG.md](../CHANGELOG.md) - Version history
- [App Store Connect](https://appstoreconnect.apple.com) - Manage releases
