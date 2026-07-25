# Activating CloudKit sync (ADR-0007 Phase 3, after Phase D)

Phase D landed the entire sync engine **inert**. All the code is written,
built, and unit-tested, but the app carries no entitlement for the sync
container, so `CloudSyncAvailability` stops at `.notEntitled` and no CloudKit
object is ever constructed.

That was deliberate: adding an `icloud-container-identifiers` entry for a
container that does not exist in the developer portal **breaks code signing for
every build** until the container is registered. So the entitlement changes
were written down here instead of applied.

This document is the mechanical checklist to flip sync on once
`iCloud.com.impress.suite` exists in the portal.

---

## 0. Prerequisite — register the container

In the Apple Developer portal: **Certificates, Identifiers & Profiles →
Identifiers → iCloud Containers → +**

| Field | Value |
|---|---|
| Description | Impress Suite Graph |
| Identifier | `iCloud.com.impress.suite` |

Then enable that container on both app identifiers (`com.impress.imbib` for
macOS and iOS) and regenerate/download the provisioning profiles. Xcode's
"Automatically manage signing" will pick them up on the next build.

**Do not proceed until the container appears in the portal** — every step below
depends on it.

---

## 1. Entitlements

### `apps/imbib/imbib/imbib/Resources/imbib.entitlements` (macOS)

Add `iCloud.com.impress.suite` to the existing container array. Keep the
existing `iCloud.com.impress.imbib` entry — removing it would orphan any legacy
data still associated with it.

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.impress.imbib</string>
    <string>iCloud.com.impress.suite</string>   <!-- ADD -->
</array>
```

`com.apple.developer.icloud-services` already contains `CloudKit` — no change.

Add push (CloudKit delivers change notifications over APNs; without it the
engine only syncs when nudged or on its 60s timer):

```xml
<key>aps-environment</key>
<string>development</string>
```

> Change `development` → `production` in the release/TestFlight configuration.
> Shipping a build with `development` silently breaks push delivery.

### `apps/imbib/imbib/imbib-iOS/Resources/imbib-iOS.entitlements`

Identical additions:

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.impress.imbib</string>
    <string>iCloud.com.impress.suite</string>   <!-- ADD -->
</array>
...
<key>aps-environment</key>
<string>development</string>
```

---

## 2. iOS Info.plist marker

macOS reads its entitlements at runtime via `SecTaskCopyValueForEntitlement`,
so the probe there is automatic. **iOS has no equivalent runtime read**, so
`CloudSyncAvailability` consults an `Info.plist` marker instead. Without this
key, the iOS app reports `.notEntitled` forever even with the entitlement
present.

In `apps/imbib/imbib/project.yml`, under the **imbib-iOS** target's `info.properties`:

```yaml
      ImpressSyncContainerIdentifier: iCloud.com.impress.suite
```

(See `CloudSyncAvailability.iOSEntitlementDeclared` for the consuming code.)

---

## 3. Regenerate the project

`.xcodeproj` files are generated and gitignored:

```bash
cd apps/imbib/imbib && xcodegen generate
```

---

## 4. Deploy the CloudKit schema

The record types are created automatically the first time a Development-
environment build saves each type. Sequence:

1. Build and run with the flag ON (Settings → Sync → Enable iCloud Sync).
2. Add a paper, star it, add a tag, delete something, create a collection —
   this exercises `ImpressItem`, `ImpressReference`, and `ImpressTombstone`.
3. Open **CloudKit Console → iCloud.com.impress.suite → Development → Schema**
   and confirm all three record types plus the `ImpressGraph` zone exist.
4. Add query indexes if you later need server-side queries — the engine itself
   uses only `CKSyncEngine` change feeds, so none are required for 3.0.
5. **Before any TestFlight/App Store build**: CloudKit Console → **Deploy
   Schema Changes** (Development → Production). A production build against an
   undeployed schema fails every save.

Record types and fields are defined in
`PublicationManagerCore/Sync/SyncRecordCodec.swift` (`RecordType`, `ItemField`,
`ReferenceField`, `TombstoneField`) — that file is the schema's source of truth.

---

## 5. Verify

```bash
# Build both platforms
cd apps/imbib/imbib && xcodebuild -scheme imbib -configuration Debug build
xcodebuild -scheme imbib-iOS -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# The gate test asserts the build is NOT entitled — it must be UPDATED once
# the entitlement lands, or it will (correctly) fail.
cd apps/imbib/PublicationManagerCore && swift test --parallel
```

**Test to update:** `SyncAvailabilityTests.testThisBuildIsNotEntitledForTheSyncContainer`
asserts `isEntitledForContainer == false`. After activation, invert it to
assert `true` on macOS. It is written as a deliberate tripwire so activation
cannot happen silently.

Then, with the app running:

```bash
curl 'http://localhost:23120/api/logs?category=sync&limit=40'
```

Expect `CloudSyncEngine started (zone ImpressGraph)` roughly 120s after launch.
Before activation the same log shows the refusal reason instead.

---

## 6. Rollout order (from the plan, Phase F)

1. Flag OFF by default — ship it dark.
2. Dogfood on two Macs in the Development environment.
3. Mac ↔ iPhone bootstrap + first-sync merge check (CloudKit does **not** work
   in the iOS simulator — use a physical device).
4. Deploy schema Development → Production **before** any TestFlight build.
5. Default ON only after the Phase F matrix passes and `/api/sync/status` stays
   clean for a week.

Escape hatch: turning the flag off is always safe. Local data is complete on
its own and the outbox is preserved, so re-enabling resumes where it stopped.

---

## What is already done (no action needed)

- Rust merge engine + convergence suite (Phases A–B).
- FFI + Swift adapter surface (Phase C).
- `SyncSettings`, `CloudSyncAvailability`, `SyncRecordCodec`, `SyncLease`,
  `CloudSyncEngine`, `SyncBootstrap`, `FirstSyncMerge`,
  `CloudSyncEngineLauncher` (Phase D).
- Launcher wired into both `imbibApp` entry points, behind the 120s grace
  delay and the flag.
- Darwin `syncApplied` notification name in ImpressKit.

Still to come (Phase E): the real Settings pane and
`GET /api/sync/status` + `POST /api/sync/nudge`.
