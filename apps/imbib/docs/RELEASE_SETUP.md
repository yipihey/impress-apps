# Release Build Setup

This guide explains how to set up automated builds for imbib releases.

## Overview

When you push a version tag (e.g., `v1.2.1`), GitHub Actions will automatically:
1. Build the macOS app with Safari extension
2. Sign it with your Developer ID certificate
3. Notarize it with Apple
4. Create a DMG installer
5. Upload the DMG to the GitHub release

## Prerequisites

- Apple Developer Program membership ($99/year)
- Developer ID Application certificate
- Xcode installed locally (for certificate export)

## GitHub Secrets Setup

Go to your repository → Settings → Secrets and variables → Actions → New repository secret

You need to add these secrets:

### 1. MACOS_CERTIFICATE_BASE64

Your Developer ID Application certificate exported as base64.

**To create this:**

1. Open Keychain Access
2. Find "Developer ID Application: Your Name (TEAM_ID)"
3. Right-click → Export → Save as `.p12` file
4. Choose a strong password (you'll need it for the next secret)
5. Convert to base64:
   ```bash
   base64 -i Certificates.p12 | pbcopy
   ```
6. Paste the result as the secret value

### 2. MACOS_CERTIFICATE_PASSWORD

The password you used when exporting the .p12 certificate.

### 3. KEYCHAIN_PASSWORD

Any random password for the temporary keychain (e.g., `build-keychain-password-123`).

### 4. APPLE_TEAM_ID

Your 10-character Apple Developer Team ID.

**To find it:**
- Go to https://developer.apple.com/account
- Look in the top-right under your name, or
- In Xcode: Preferences → Accounts → Select team → View Details

Example: `ABC1234DEF`

### 5. APPLE_ID

Your Apple ID email address used for notarization.

Example: `developer@example.com`

### 6. APPLE_APP_PASSWORD

An app-specific password for notarization (NOT your Apple ID password).

**To create one:**
1. Go to https://appleid.apple.com/account/manage
2. Sign in → Security → App-Specific Passwords
3. Click "Generate" → Name it "GitHub Actions imbib"
4. Copy the generated password (format: `xxxx-xxxx-xxxx-xxxx`)

## Local Builds

For building releases locally without GitHub Actions:

```bash
# Install prerequisites
brew install xcodegen create-dmg

# Run the build script
./scripts/build-release.sh v1.2.1

# Or with environment variables
APPLE_ID="you@example.com" \
APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
TEAM_ID="ABC1234DEF" \
./scripts/build-release.sh v1.2.1
```

The DMG will be created in `build/imbib-v1.2.1-macOS.dmg`.

## Creating a Release

### Option 1: Automatic (GitHub Actions)

```bash
# Tag and push
git tag v1.3.0
git push origin v1.3.0
```

GitHub Actions will build and attach the DMG to the release automatically.

### Option 2: Manual

```bash
# Build locally
./scripts/build-release.sh v1.3.0

# Create release and upload
gh release create v1.3.0 \
  --title "v1.3.0 - Release Title" \
  --notes "Release notes here" \
  build/imbib-v1.3.0-macOS.dmg
```

## Troubleshooting

### Certificate not found

Make sure the certificate name matches exactly: "Developer ID Application"

Check available certificates:
```bash
security find-identity -v -p codesigning
```

### Notarization failed

- Verify app-specific password is correct
- Check Apple ID has accepted latest agreements at developer.apple.com
- Review notarization log:
  ```bash
  xcrun notarytool log <submission-id> \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$TEAM_ID"
  ```

### Safari extension not in bundle

Verify the extension target is listed in project.yml with `embed: true`:
```yaml
dependencies:
  - target: imbib-SafariExtension
    embed: true
```

## Verifying the Build

After building, verify the Safari extension is included:

```bash
# Check bundle contents
ls -la "build/export/imbib.app/Contents/PlugIns/"
# Should show: imbib Safari Extension.appex

# Verify code signature
codesign -dv --verbose=4 "build/export/imbib.app"

# Verify notarization
spctl -a -v "build/export/imbib.app"
# Should show: accepted, source=Notarized Developer ID
```
