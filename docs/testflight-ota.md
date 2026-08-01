# Over-the-Air Delivery — TestFlight for imbib-iOS & imprint-iOS

**Goal:** push a ready iOS build to the iPhone **without a cable**, so a finished
build is never stranded because the user is away from the Mac (as happened
2026-07-24 with the tailnet remote-access build `1c706cf`).

The lane is **internal TestFlight only**. It never submits for App Review.

| App | Scheme | Bundle ID | Team |
|-----|--------|-----------|------|
| imbib | `imbib-iOS` | `com.impress.imbib` | `QG3MEYVHMS` |
| imprint | `imprint-iOS` | `com.imbib.imprint` | `QG3MEYVHMS` |

Both iOS apps share their bundle ID with their macOS sibling, so **one App Store
Connect record per app** covers every platform.

---

## TL;DR — the one command

Once the one-time setup below is done, every future build is a single command:

```bash
./scripts/archive-and-upload.sh both
```

That archives both iOS schemes, exports signed IPAs (`method: app-store-connect`),
and uploads them to TestFlight. Then add the processed build to the internal
tester group and it appears in the TestFlight app on the iPhone — no cable.

Single app / explicit version:

```bash
./scripts/archive-and-upload.sh imbib v1.3.0
```

---

## One-time setup

### 1. App Store Connect app records (a person must do this)

Claude cannot log into App Store Connect. Confirm (or create) an app record for
each bundle ID at <https://appstoreconnect.apple.com/apps> → **＋ → New App**:

- **imbib** — bundle `com.impress.imbib`, platform iOS
- **imprint** — bundle `com.imbib.imprint`, platform iOS

If a record does not exist yet, create it (SKU can be the bundle ID; no pricing
or App Review needed for TestFlight). The App IDs themselves already exist in the
Developer Portal — `-allowProvisioningUpdates` maintains the provisioning
profiles automatically at archive time.

### 2. App Store Connect API key

TestFlight uploads authenticate with an **API key** (not an Apple ID password),
which keeps the whole lane non-interactive.

1. <https://appstoreconnect.apple.com/access/api> → **Keys** tab → **＋**.
2. Role: **App Manager** (Admin also works).
3. Download the `AuthKey_<KEYID>.p8` (Apple lets you download it **once**) into:

   ```bash
   mkdir -p ~/.appstoreconnect/private_keys
   mv ~/Downloads/AuthKey_<KEYID>.p8 ~/.appstoreconnect/private_keys/
   ```

4. Note the **Key ID** (on the key row) and the **Issuer ID** (top of the Keys
   tab — one per account).

Store them in the Keychain so no build needs environment variables:

```bash
./scripts/archive-and-upload.sh --setup
```

This writes to the same Keychain services imbib's existing
`apps/imbib/scripts/ios-testflight.sh` already uses
(`imbib-testflight` for the key/issuer, `imbib-release` for the team ID), so
setup is shared across scripts.

> The script can **infer the Key ID** from the filename when exactly one
> `AuthKey_*.p8` is present, and defaults the Team ID to `QG3MEYVHMS`. In
> practice the only value you must supply is the **Issuer ID**. It can also be
> passed ad hoc: `ASC_ISSUER_ID=… ./scripts/archive-and-upload.sh both`.

### 3. Internal tester group (a person must do this, once per app)

In App Store Connect → your app → **TestFlight** → **Internal Testing** → **＋**:

- Create a group (e.g. "Self").
- Add the user's Apple ID (`tabel@stanford.edu`) as a tester.

Internal testers need **no App Review** and get builds the moment processing
finishes. Up to 100 internal testers; builds stay available for 90 days.

---

## Every subsequent build

```bash
./scripts/archive-and-upload.sh both          # both apps
./scripts/archive-and-upload.sh imprint       # one app
```

Pipeline per app: `xcodegen generate` → `xcodebuild archive`
(`-allowProvisioningUpdates`, API-key auth) → `-exportArchive` → `altool
--upload-app`. The version comes from the latest git tag (override with a
`vX.Y.Z` argument); the build number is `<commit-count>.<YYMMDDHHMM>`, which is
strictly increasing so App Store Connect never rejects a duplicate.

Useful flags:

| Flag | Effect |
|------|--------|
| `--no-upload` | archive + export the `.ipa` only (no upload) |
| `--validate` | `altool --validate-app` before uploading |
| `--rebuild-frameworks` | rebuild the app's Rust XCFramework (iOS slices) first |
| `--no-generate` | skip `xcodegen generate`; archive the project as-is |

> **xcodegen:** the script regenerates the `.xcodeproj` from `project.yml` before
> archiving so the build always matches source. If you edit a `project.yml`,
> that regeneration picks it up automatically. Rust XCFrameworks already carry
> `ios-arm64` device slices, so a framework rebuild is **not** required for a
> normal push — use `--rebuild-frameworks` only after changing Rust code.

## After the upload — get it onto the iPhone

1. **Processing** (~5–20 min): App Store Connect ingests and re-signs the build.
   You'll get an email when it's ready, or watch the app's TestFlight tab.
2. **Assign the build:** app → TestFlight → your internal group → **Builds** →
   add the new build. (Internal builds skip the "Beta App Review" that only
   external testers require.)
3. **Install:** open the **TestFlight** app on the iPhone → the app → **Install**
   / **Update**. Done — entirely over the air.

Enable "Automatic Updates" in the TestFlight app once, and future pushes install
themselves after processing.

---

## Troubleshooting

- **`cannot upload without credentials`** — the Issuer ID isn't set. Run
  `--setup`, or prefix with `ASC_ISSUER_ID=…`.
- **`No profiles for 'com.…' were found`** — the App Store Connect app record
  doesn't exist yet, or the API key lacks App Manager rights. Create the record
  (step 1) and confirm the key role (step 2). `-allowProvisioningUpdates` then
  regenerates the profile on the next run.
- **`Redundant binary upload … bundle version … already exists`** — you re-ran
  within the same minute (build numbers are minute-resolution). Re-run; the next
  timestamp differs.
- **Archive can't find the Rust library / undefined symbols** — the iOS slice is
  stale or missing. Re-run with `--rebuild-frameworks`, or rebuild everything:
  `./scripts/build-xcframeworks.sh`.
- **Build never leaves "Processing"** — almost always a missing export-compliance
  answer. Set `ITSAppUsesNonExemptEncryption` in each app's `Info.plist`
  (`imbib-iOS/Resources/Info.plist`, `imprint-iOS/Info.plist`) to avoid the
  per-build prompt.

## Related

- `scripts/archive-and-upload.sh` — the lane itself (self-documenting `--help`).
- `apps/imbib/scripts/ios-testflight.sh` — imbib's older single-app uploader;
  superseded by the unified script but shares the same Keychain credentials.
- `apps/imbib/scripts/invite-tester.sh` — programmatically add TestFlight testers
  via the App Store Connect API.
