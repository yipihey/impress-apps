# Privacy Policy for Impress Apps

**Effective Date:** January 27, 2026
**Last Updated:** January 27, 2026

This privacy policy describes how the Impress apps suite ("we", "our", or "the apps") collects, uses, and protects your information. The Impress suite includes:

- **imbib** — Scientific publication manager
- **imprint** — Collaborative academic document editor
- **implore** — Scientific data visualization tool
- **impel** — Agent orchestration dashboard

We are committed to protecting your privacy. Our apps are designed with privacy-first principles: no analytics, no tracking, no crash reporting to external services.

---

## Summary

| What We Collect | Why | Where Stored |
|-----------------|-----|--------------|
| Publication metadata | Core app functionality | Local device; also iCloud if you turn sync on (off by default) |
| API credentials you provide | Access academic databases | Device Keychain (encrypted) |
| Search queries | Retrieve academic literature | Sent to academic APIs, not logged |
| Documents you create | Core app functionality | Local device; manuscript metadata and bodies under 1 MB also sync if you turn sync on |
| App preferences | Personalization | Local device only |

**We do NOT collect:** Personal identifiers, usage analytics, location data, contacts, or any data for advertising purposes.

---

## Information Collection by App

### imbib (Publication Manager)

#### Data Stored Locally
- **Publication library**: Titles, authors, abstracts, citations, tags, notes, and reading positions
- **PDF files**: Stored with human-readable names in your chosen location
- **BibTeX/RIS files**: Your bibliography in open, portable formats
- **App preferences**: UI settings, keyboard shortcuts, enrichment preferences

#### Data Synced via iCloud (Optional, off by default)
Sync is **disabled by default**. If you turn it on in Settings:
- The shared impress graph store — publications, manuscripts, tags, and the
  links between them — syncs to the **private** database of your own iCloud
  account, in the `iCloud.com.impress.suite` container
- Only you can access this data, through your Apple ID; there is no sharing
  with other users and no server we operate
- You can disable sync at any time in Settings; your data stays on the device
- API credentials are **never** synced

#### API Credentials
When you provide API keys for academic services (NASA ADS, Web of Science, etc.):
- Stored encrypted in your device's Keychain
- Never transmitted except to the respective API service
- Never synced to iCloud
- You can remove them at any time in Settings

#### External API Requests
imbib connects to academic databases to search and retrieve publication metadata:

| Service | Data Sent | Authentication |
|---------|-----------|----------------|
| NASA ADS | Search queries, DOI/arXiv lookups | Your API key |
| Web of Science | Search queries | Your API key |
| arXiv | Search queries | None required |
| Crossref | Search queries, DOI lookups | None (optional email for rate limits) |
| OpenAlex | Search queries | None (optional email for rate limits) |
| PubMed | Search queries | None (optional API key) |

**What we send**: Only the search query or identifier needed to retrieve results.
**What we don't send**: Your library contents, personal information, or device identifiers.

### imprint (Document Editor)

- **Documents**: Stored as local files (.imprint packages) on your device
- **No cloud sync**: Documents remain on your device unless you manually share them
- **No external APIs**: Document editing works entirely offline
- **Citation integration**: If connected to imbib, search queries use imbib's API connections

### implore (Data Visualization)

- **Figure library**: Stored locally in `~/Library/Application Support/implore/`
- **No cloud sync**: All data remains on your device
- **No external APIs**: Visualization works entirely offline

### impel (Agent Dashboard)

- **No persistent user data**: Monitoring dashboard with no local storage
- **Server connection**: Connects to your configured impel server
- **No data sent externally**: Communication only with your own server

---

## Data We Do NOT Collect

We want to be explicit about what we don't do:

- **No analytics**: We don't use any analytics services (no Google Analytics, Amplitude, Mixpanel, etc.)
- **No tracking**: We don't track your behavior, clicks, or usage patterns
- **No advertising**: We don't collect data for advertising purposes
- **No crash reporting**: We don't send crash reports to external services
- **No telemetry**: We don't phone home or send usage statistics
- **No user accounts**: We don't require registration or collect email addresses
- **No third-party SDKs**: We don't embed tracking SDKs

---

## iCloud Sync (suite-wide, off by default)

Sync covers the shared impress graph store used by all impress apps, not just
imbib. It runs in one container, `iCloud.com.impress.suite`, entirely within
your own private iCloud database.

### What Syncs
- Publication metadata (titles, authors, abstracts, citations, tags, notes)
- Library organization (collections, smart searches)
- Reading positions
- Manuscript metadata, and manuscript bodies **under 1 MB**
- Some cross-device app settings, via iCloud key-value storage

### What Does NOT Sync
- **PDF files and other attachments** — these stay on the device that has them
- **Manuscript bodies over 1 MB** — stored outside the synced store; other
  devices see the manuscript but report the body as unavailable
- API credentials (stored only in the device Keychain)
- Undo history and operation history (per-device)
- Preferences not explicitly listed as synced settings

### Your Control
- Sync is **optional and off by default**; you turn it on in imbib's Settings
- Turning it off is always safe — your data is local and stays local
- When off, nothing leaves your device except the academic API requests you
  explicitly make
- Only imbib runs the sync engine; changes made in imprint or impel are queued
  and upload the next time imbib is running

### Apple's Role
iCloud data is governed by [Apple's Privacy Policy](https://www.apple.com/legal/privacy/). Data is encrypted in transit and at rest in Apple's data centers.

---

## Third-Party Services

### Academic Database APIs

When you search for publications, imbib sends queries to academic databases. These services have their own privacy policies:

- [NASA ADS Privacy Policy](https://ui.adsabs.harvard.edu/help/privacy/)
- [Crossref Privacy Policy](https://www.crossref.org/privacy/)
- [arXiv Privacy Policy](https://arxiv.org/help/policies/privacy_policy)
- [PubMed Privacy Policy](https://www.ncbi.nlm.nih.gov/home/about/policies/)
- [OpenAlex Terms](https://openalex.org/terms)
- [Clarivate Privacy (Web of Science)](https://clarivate.com/privacy-center/)

We only send the minimum data required (search queries and identifiers). We do not send your library contents, personal information, or device identifiers to these services.

### No Other Third Parties

We do not share your data with any other third parties. We do not sell, rent, or trade your information.

---

## Data Security

### Encryption
- **API credentials**: Encrypted in your device's Keychain
- **iCloud sync**: Encrypted in transit (TLS) and at rest by Apple
- **Local storage**: Protected by your device's security (FileVault, device encryption)

### Access Control
- Only you can access your data through your Apple ID (for iCloud)
- API credentials are stored with `afterFirstUnlock` accessibility
- No remote access to your local data

---

## Your Rights and Controls

### Access Your Data
- Export your library as BibTeX or RIS at any time
- PDFs are stored in standard formats you can access directly
- imprint documents are standard file packages

### Delete Your Data
- Delete individual publications or entire libraries in-app
- Remove API credentials in Settings
- Uninstalling the app removes local data
- iCloud data can be managed through iCloud settings

### Disable Features
- iCloud sync is off unless you enable it in Settings (imbib); disable it there at any time
- Remove API keys to prevent external searches
- Use offline mode for local-only operation

### Data Portability
- BibTeX and RIS are open, portable formats
- No vendor lock-in for your publication data
- imprint uses Typst, an open document format

---

## Children's Privacy

Our apps are not directed at children under 13. We do not knowingly collect information from children under 13. If you believe a child has provided us with personal information, please contact us.

---

## Changes to This Policy

We may update this privacy policy from time to time. We will notify you of significant changes by:
- Updating the "Last Updated" date
- Including a notice in app release notes

---

## Contact Us

If you have questions about this privacy policy or our data practices:

- **GitHub Issues**: [github.com/impress-apps/impress-apps/issues](https://github.com/impress-apps/impress-apps/issues)
- **Email**: privacy@impress.app

---

## App Store Compliance

This privacy policy is designed to comply with:
- Apple App Store Guidelines
- GDPR (General Data Protection Regulation)
- CCPA (California Consumer Privacy Act)

---

*This privacy policy applies to all Impress apps distributed through the Apple App Store and direct download.*
