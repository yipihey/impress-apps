# Release Credential Setup

This guide covers the one-time setup of credentials needed for imbib releases.

For release workflows, see [RELEASE_GUIDE.md](RELEASE_GUIDE.md).

## Quick Setup

Run the interactive setup wizard:

```bash
./scripts/release.sh setup
```

This configures all credentials in macOS Keychain.

## Prerequisites

Before setting up credentials, you need:

1. **Apple Developer Program membership** ($99/year)
   - https://developer.apple.com/programs/

2. **Signing certificates in Keychain:**
   - "Developer ID Application" - for DMG distribution
   - "Apple Distribution" - for App Store/TestFlight

3. **App Store Connect API key:**
   - https://appstoreconnect.apple.com/access/api
   - Role: "App Manager" or "Admin"

## Credential Details

### 1. Team ID

Your 10-character Apple Developer Team ID.

**Where to find it:**
- https://developer.apple.com/account → Membership
- Or in Xcode: Settings → Accounts → Select team

**Example:** `ABC1234DEF`

### 2. Notarization Credentials (for DMG)

Used to notarize DMG files for direct distribution.

**Apple ID:** Your Apple Developer email address.

**App-Specific Password:**
1. Go to https://appleid.apple.com/account/manage
2. Sign in → Security → App-Specific Passwords
3. Click "Generate" → Name it "imbib releases"
4. Copy the generated password (format: `xxxx-xxxx-xxxx-xxxx`)

### 3. App Store Connect API Key (for TestFlight)

Used to upload builds to TestFlight and App Store.

**Create the key:**
1. Go to https://appstoreconnect.apple.com/access/api
2. Click the "+" button to create a new key
3. Name: "imbib releases"
4. Access: "App Manager" or "Admin"
5. Click "Generate"

**Save the key file:**
1. Download the `.p8` file (you can only download once!)
2. Save it to:
   ```bash
   mkdir -p ~/.appstoreconnect/private_keys
   mv ~/Downloads/AuthKey_XXXXXXXX.p8 ~/.appstoreconnect/private_keys/
   ```

**Note the IDs:**
- **Key ID:** Shown in the key list (e.g., `ABC123DEFG`)
- **Issuer ID:** Shown at the top of the API keys page

## GitHub Secrets (for CI/CD)

For GitHub Actions to build releases automatically, add these secrets:

Go to: Repository → Settings → Secrets and variables → Actions

| Secret | Description |
|--------|-------------|
| `MACOS_CERTIFICATE_BASE64` | Developer ID certificate as base64 |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the .p12 file |
| `KEYCHAIN_PASSWORD` | Any random password for temp keychain |
| `APPLE_TEAM_ID` | Your 10-character Team ID |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_APP_PASSWORD` | App-specific password |

### Exporting the Certificate

1. Open Keychain Access
2. Find "Developer ID Application: Your Name"
3. Right-click → Export → Save as `.p12`
4. Choose a strong password
5. Convert to base64:
   ```bash
   base64 -i Certificates.p12 | pbcopy
   ```
6. Paste as `MACOS_CERTIFICATE_BASE64` secret

## Keychain Reference

Credentials are stored in macOS Keychain:

| Service | Account | Description |
|---------|---------|-------------|
| `imbib-release` | `team-id` | Apple Developer Team ID |
| `imbib-release` | `apple-id` | Apple ID for notarization |
| `imbib-release` | `app-password` | App-specific password |
| `imbib-testflight` | `asc-key-id` | App Store Connect Key ID |
| `imbib-testflight` | `asc-issuer-id` | App Store Connect Issuer ID |

### Manual Keychain Commands

```bash
# View a credential
security find-generic-password -s "imbib-release" -a "team-id" -w

# Add/update a credential
security add-generic-password -U -a "team-id" -s "imbib-release" -w "ABC1234DEF"

# Delete a credential
security delete-generic-password -s "imbib-release" -a "team-id"
```

## Verification

After setup, verify credentials:

```bash
./scripts/release.sh status
```

Expected output:
```
Credentials:
  Team ID:         ✓ configured
  Notarization:    ✓ configured (you@example.com)
  App Store API:   ✓ configured (key: ABC123DEFG)
```

## Troubleshooting

### "No signing certificate found"

1. Open Keychain Access
2. Check for "Developer ID Application" (DMG) or "Apple Distribution" (App Store)
3. If missing:
   - Download from https://developer.apple.com/account/resources/certificates
   - Or create via Xcode: Settings → Accounts → Manage Certificates

### "API key file not found"

The `.p8` file must be in the correct location:
```bash
~/.appstoreconnect/private_keys/AuthKey_KEYID.p8
```

Check:
```bash
ls ~/.appstoreconnect/private_keys/
```

### "Invalid app-specific password"

1. Go to https://appleid.apple.com/account/manage
2. Revoke the old password
3. Generate a new one
4. Update in Keychain:
   ```bash
   ./scripts/release.sh setup
   ```

## Related Documentation

- [RELEASE_GUIDE.md](RELEASE_GUIDE.md) - How to perform releases
- [Apple Developer Documentation](https://developer.apple.com/documentation/)
- [App Store Connect Help](https://developer.apple.com/help/app-store-connect/)
