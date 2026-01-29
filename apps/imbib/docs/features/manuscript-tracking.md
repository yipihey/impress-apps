---
layout: default
title: Manuscript Tracking
---

# Manuscript Tracking

Track your own papers through the publication process and integrate with imprint for writing.

---

## Overview

imbib can track manuscripts you're writing, not just papers you're reading. Manuscript tracking provides:

- **Status tracking** - From drafting through publication
- **Citation management** - Track papers you cite
- **Version control** - Organize submission and revision documents
- **imprint integration** - Seamless workflow with imprint writing app

---

## Creating a Manuscript Entry

### From Scratch

1. Go to **File > New > Manuscript**
2. Enter title and basic metadata
3. Set initial status (usually "Drafting")

### From Existing Paper

If your paper is already in your library (e.g., after arXiv submission):

1. Select the paper
2. Go to **Paper > Convert to Manuscript**
3. The paper gains manuscript tracking features

---

## Manuscript Status

Track your paper's progress through the publication workflow:

| Status | Icon | Description |
|--------|------|-------------|
| **Drafting** | Pencil | Initial writing phase |
| **Submitted** | Paper plane | Sent to journal |
| **Under Review** | Eye | Being reviewed |
| **In Revision** | Arrows | Revising based on feedback |
| **Accepted** | Checkmark | Accepted for publication |
| **Published** | Book | Final publication |
| **Rejected** | X | Rejected (can resubmit elsewhere) |

### Changing Status

1. Select the manuscript
2. Go to **Paper > Manuscript Status**
3. Choose the new status

Or use the status dropdown in the Info tab.

### Status Collections

Manuscripts appear in special sidebar collections:

- **My Manuscripts** - All manuscripts
- **Active** - Drafting, Submitted, Under Review, In Revision
- **Completed** - Accepted, Published

---

## Citation Tracking

### Linking Cited Papers

Track which papers your manuscript cites:

1. Select your manuscript
2. Go to the **Citations** section in Info tab
3. Click **Add Citation**
4. Search or select papers from your library

### Citation Intelligence

imbib provides insights about your citations:

- **Cited by this manuscript** - Papers you're citing
- **Also cited in** - Other manuscripts citing the same papers
- **Read but uncited** - Papers you've read but haven't cited

### Bibliography Generation

Export citations as BibTeX for your manuscript:

1. Select the manuscript
2. Go to **Paper > Export > Bibliography...**
3. Exports all cited papers as `.bib`

---

## Document Versions

### Attachment Tags

Organize manuscript versions with tags:

| Tag | Use For |
|-----|---------|
| **Submission v1/v2/v3** | Submitted versions |
| **Revision R1/R2/R3** | Revision rounds |
| **Referee Report** | Reviewer feedback |
| **Response Letter** | Your responses |
| **Final Accepted** | Accepted manuscript |
| **Published** | Published version |
| **Proofs** | Proof copies |
| **Cover Letter** | Submission cover letter |
| **Supplementary** | Supplementary materials |

### Tagging Attachments

1. Drag a document onto the manuscript
2. Right-click the attachment
3. Select **Set Manuscript Tag**
4. Choose the appropriate tag

### Version History

The Attachments section shows:
- All versions in chronological order
- Tags color-coded by type
- Date each version was added

---

## imprint Integration

### What is imprint?

imprint is a companion writing app for scientific manuscripts. It provides:
- Typst-based typesetting
- Live preview
- Citation insertion from imbib

### Linking to imprint

1. Select your manuscript
2. Go to **Paper > Link to imprint Document**
3. Choose an existing `.imprint` document or create new

### Opening in imprint

Once linked:
- Click the imprint icon in the Info tab
- Or use **Paper > Open in imprint**
- The document opens at your last position

### Citation Workflow

When writing in imprint:
1. Press **Cmd+Shift+K** to insert citation
2. Search your imbib library
3. Select papers to cite
4. Citations are tracked in both apps

### Compiled PDF

imprint can automatically send compiled PDFs back to imbib:
- Tagged as "Compiled PDF"
- Updated on each compile
- Always have the latest version in imbib

---

## Manuscript Metadata

### Additional Fields

Manuscripts have extra metadata:

| Field | Description |
|-------|-------------|
| **Submission Venue** | Target journal or conference |
| **Submission Date** | When submitted |
| **Acceptance Date** | When accepted |
| **Revision Number** | Current revision round |
| **Coauthor Emails** | For collaboration features |

### Editing Metadata

1. Select the manuscript
2. Go to the Info tab
3. Click **Edit Manuscript Info**
4. Update fields as needed

---

## Workflows

### Initial Submission

1. Create manuscript entry (status: Drafting)
2. Link to imprint document
3. Add cited papers as you write
4. When ready, change status to Submitted
5. Attach submission PDF with "Submission v1" tag

### Handling Reviews

1. Receive reviewer comments
2. Add referee reports with "Referee Report" tag
3. Change status to "In Revision"
4. Write response letter, attach with "Response Letter" tag
5. Submit revision, attach with "Revision R1" tag
6. Change status back to "Submitted" or "Under Review"

### After Acceptance

1. Change status to "Accepted"
2. Attach final accepted manuscript
3. Attach proofs when received
4. Change status to "Published" when live
5. Add DOI to the entry

---

## Troubleshooting

### imprint Not Found

If "Open in imprint" doesn't work:
1. Verify imprint is installed
2. Check the linked document still exists
3. Try re-linking the document

### Citation Count Wrong

If citation count seems off:
1. Check for duplicate citations
2. Verify all cited papers are in your library
3. Use **Refresh Citations** to update

### Status Not Syncing

Status syncs via iCloud:
1. Ensure iCloud sync is enabled
2. Check for sync errors in Console
3. Force sync in Settings

---

## See Also

- [Collections](../features#collections) - Organizing papers
- [Import & Export](../features#import--export) - Exporting bibliographies
- [iCloud Sync](../platform/ios-guide#icloud-sync) - Syncing across devices
