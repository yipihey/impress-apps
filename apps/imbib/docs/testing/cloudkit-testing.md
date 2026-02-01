# CloudKit Testing Guide

This document describes how to properly test CloudKit sync in imbib, including how to avoid common pitfalls like sandbox/production confusion.

---

## Understanding CloudKit Environments

CloudKit has two separate environments:

| Environment | When Used | Data Location |
|-------------|-----------|---------------|
| **Sandbox** | Running from Xcode | Separate sandbox database |
| **Production** | App Store, TestFlight, direct distribution | Production iCloud database |

**Critical:** Sandbox and production are completely separate. Data synced in sandbox will NOT appear in production, and vice versa.

### How to Know Which Environment You're In

1. **Check the console logs** for:
   - "CloudKit environment detected: sandbox" (running from Xcode)
   - "CloudKit environment detected: production" (App Store/TestFlight)

2. **Check Settings > Sync** in the app:
   - A warning banner appears when running in sandbox mode

3. **Use the environment detection code:**
   ```swift
   let env = await CloudKitEnvironmentDetector.shared.detectEnvironment()
   print("Environment: \(env.rawValue)")
   ```

---

## Testing Scenarios

### Scenario 1: Fresh Install Experience

Test what a new user sees on first launch.

1. Run the fresh install script:
   ```bash
   ./scripts/test-fresh-install.sh
   ```

2. Launch the app from Xcode

3. Verify:
   - [ ] Welcome/onboarding screen appears
   - [ ] User can create a new library
   - [ ] Console shows: "Using canonical default library ID for first library"
   - [ ] Library ID is `00000000-0000-0000-0000-000000000001`

### Scenario 2: Cross-Device Sync (Same Environment)

Test that data syncs between two devices in the same CloudKit environment.

**Setup:**
- Two devices (or one device + simulator) signed into the same iCloud account
- Both running the same CloudKit environment (both sandbox OR both production)

**Test:**
1. On Device A: Create a library named "Test Library"
2. Wait for CloudKit sync (observe console for sync logs)
3. On Device B: Launch app
4. Verify: "Test Library" appears on Device B

### Scenario 3: Library Deduplication

Test that duplicate libraries are properly merged.

1. On Device A:
   - Run fresh install script
   - Launch app and create default library "My Library"
   - Add a paper to the library

2. On Device B (before sync completes):
   - Run fresh install script
   - Launch app and create default library "My Library"
   - Add a different paper

3. Wait for CloudKit sync to complete on both devices

4. Verify on both devices:
   - Only ONE "My Library" exists
   - Both papers are present in the merged library
   - Console shows: "Library merge:" logs

### Scenario 4: Production Verification

Test before App Store submission.

1. Create an Archive build:
   ```bash
   xcodebuild archive -scheme imbib -archivePath ~/Desktop/imbib.xcarchive
   ```

2. Run the release verification script:
   ```bash
   ./scripts/verify-release.sh ~/Desktop/imbib.xcarchive
   ```

3. Verify:
   - [ ] CloudKit environment is "Production"
   - [ ] All entitlements are correct
   - [ ] No sandbox contamination warnings

---

## Test Apple IDs

### Creating Test Apple IDs

For testing CloudKit sync, you need at least two Apple IDs:

1. **Primary Test Account**
   - Use for main development and testing
   - Keep data minimal to make testing easier

2. **Secondary Test Account**
   - Use to test cross-account scenarios
   - Test shared libraries, permissions

**To create a test Apple ID:**
1. Go to https://appleid.apple.com/account
2. Use a unique email (can use + addressing: `yourname+test1@gmail.com`)
3. Verify the email
4. Sign in on your test device

### Sandbox vs Production with Test Accounts

**Important:** The same Apple ID has separate data in sandbox and production.

If you've been testing in sandbox and want to test fresh production:
1. Sign out of iCloud on the device
2. Sign in with a fresh Apple ID (or one never used in production)
3. Install the production build

---

## Xcode Schemes for Testing

### Isolated Testing Scheme

Create an Xcode scheme for isolated CloudKit testing:

1. Duplicate the main "imbib" scheme
2. Rename to "imbib-CloudKit-Test"
3. Edit scheme:
   - Run > Arguments > Environment Variables:
     - Add: `CLOUDKIT_TEST_MODE` = `1`
   - Run > Options:
     - Check "Allow Location Simulation" (helps with iCloud availability)

### Fresh Install Testing Scheme

1. Duplicate the main scheme
2. Rename to "imbib-Fresh-Install"
3. Edit scheme:
   - Run > Arguments > Arguments Passed On Launch:
     - Add: `--show-welcome-screen`
   - Run > Pre-actions:
     - Add: Run Script
     - Script: `./scripts/test-fresh-install.sh --no-confirm`

---

## Common Issues and Solutions

### Issue: "Data doesn't sync between devices"

**Possible causes:**
1. Devices are in different CloudKit environments (sandbox vs production)
   - **Fix:** Ensure both run from same source (both Xcode OR both installed)

2. Different iCloud accounts
   - **Fix:** Verify same Apple ID on both devices

3. iCloud Drive disabled
   - **Fix:** Settings > [Your Name] > iCloud > iCloud Drive: ON

4. Network issues
   - **Fix:** Check both devices have internet; try toggling airplane mode

### Issue: "Library appears multiple times"

**Cause:** Libraries created on different devices before sync completed.

**Fix:**
1. The deduplication service should merge them automatically
2. If not, trigger it manually:
   ```swift
   await LibraryManager.shared.runDeduplication()
   ```
3. Check console for merge results

### Issue: "Sync works in Xcode but not in TestFlight"

**Cause:** Likely environment mismatch or entitlement issue.

**Fix:**
1. Run `./scripts/verify-release.sh` on the TestFlight build
2. Verify CloudKit container is configured in App Store Connect
3. Check the CloudKit Dashboard for errors

### Issue: "Can't tell if I'm in sandbox or production"

**Fix:**
1. Check console for "CloudKit environment detected: X"
2. Check Settings in the app for sandbox warning banner
3. Use CloudKit Dashboard:
   - Sandbox: https://icloud.developer.apple.com/dashboard (select Development)
   - Production: https://icloud.developer.apple.com/dashboard (select Production)

---

## CloudKit Dashboard

Access at: https://icloud.developer.apple.com/dashboard

### Useful Operations

1. **View Records:** See what's actually in CloudKit
2. **Delete Records:** Clean up test data (be careful in production!)
3. **Check Subscriptions:** Verify sync subscriptions exist
4. **View Logs:** Debug sync failures

### Environment Selection

At the top of the dashboard, you can switch between:
- **Development** (sandbox)
- **Production**

Make sure you're viewing the right environment when debugging!

---

## Automated Testing

### Unit Tests for CloudKit Code

Location: `Tests/PublicationManagerCoreTests/Sync/`

Run:
```bash
cd apps/imbib/PublicationManagerCore
swift test --filter Sync
```

### Fresh Install Tests

Location: `Tests/PublicationManagerCoreTests/Onboarding/FreshInstallTests.swift`

Tests:
- Default library uses canonical UUID
- Welcome screen flag detection
- Initial library state

### Library Deduplication Tests

Location: `Tests/PublicationManagerCoreTests/Sync/LibraryDeduplicationTests.swift`

Tests:
- Canonical ID merge
- Name-based merge
- Publication migration during merge

---

## Pre-Release Checklist

Before releasing a build that involves CloudKit changes:

- [ ] Test fresh install on clean device
- [ ] Test sync between two devices (same environment)
- [ ] Test library deduplication
- [ ] Run `./scripts/verify-release.sh`
- [ ] Verify CloudKit schema in Dashboard (if model changed)
- [ ] Check CloudKit Dashboard for any errors
- [ ] Test on both macOS and iOS
- [ ] Test upgrade from previous version (not just fresh install)

---

## References

- [CloudKit Documentation](https://developer.apple.com/documentation/cloudkit)
- [NSPersistentCloudKitContainer](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer)
- [CloudKit Dashboard](https://icloud.developer.apple.com/dashboard)
- [imbib ADR-007: Conflict Resolution](../adr/007-conflict-resolution.md)
