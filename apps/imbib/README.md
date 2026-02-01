<p align="center">
  <img src="docs/assets/images/logo.png" alt="imbib" width="128" height="128">
</p>

<h1 align="center">imbib</h1>

<p align="center">
  <strong>Subscribe to Science.</strong><br>
  <em>Your research inbox. Every database. One library.</em>
</p>

<p align="center">
  <a href="https://github.com/yipihey/impress-apps/releases">Download</a> &bull;
  <a href="https://yipihey.github.io/impress-apps/">Documentation</a> &bull;
  <a href="https://github.com/yipihey/impress-apps/issues">Report Issue</a>
</p>

<p align="center">
  <strong>🧪 Beta Testing Available!</strong><br>
  <a href="https://testflight.apple.com/join/XXXXXX">Join TestFlight</a> to try the latest features on macOS and iOS
</p>

---

**imbib** is a reference manager for macOS and iOS that combines unified search across NASA ADS, arXiv, Crossref, and more with an email-style inbox for triaging new papers.

## Why imbib?

- **BibTeX-Native** - Your `.bib` files remain the source of truth. Full BibDesk compatibility.
- **Unified Search** - Search ADS, arXiv, Crossref, Semantic Scholar, OpenAlex, and DBLP from one interface. Results are deduplicated automatically.
- **Smart Searches** - Save queries that refresh automatically and feed new papers to your Inbox.
- **Inbox Triage** - Star, archive, or dismiss papers with keyboard shortcuts. Like email, but for science.
- **Browser Extensions** - Save papers from Safari, Chrome, Firefox, or Edge with one click.
- **No Cloud Lock-in** - Your data stays on your devices. Sync via iCloud if you want.

## Installation

### macOS

**Option 1: TestFlight Beta** (Recommended for latest features)
- **[Join TestFlight Beta](https://testflight.apple.com/join/XXXXXX)** - macOS 14+

**Option 2: Stable Release**
1. Download from [Releases](https://github.com/yipihey/impress-apps/releases)
2. Move `imbib.app` to `/Applications`
3. Launch imbib

### iOS / iPadOS

**[Join TestFlight Beta](https://testflight.apple.com/join/XXXXXX)** - Available for iPhone and iPad running iOS 18+.

## Quick Start

1. **Create a library** - Choose a folder for your `.bib` file and PDFs
2. **Search for papers** - Use the search bar (ADS and arXiv enabled by default)
3. **Import papers** - Click to add papers to your library
4. **Attach PDFs** - Drag-and-drop or download from publishers

[Full Getting Started Guide](https://yipihey.github.io/impress-apps/getting-started)

## Features

| Feature | Description |
|---------|-------------|
| Multiple Libraries | Organize papers by project, topic, or collaboration |
| Smart Searches | Saved queries with auto-refresh and Inbox feeding |
| Collections | Manual folders within libraries |
| Inbox Triage | Star, archive, or dismiss papers efficiently |
| PDF Viewer | Built-in viewer with reading position memory |
| BibTeX Editor | Syntax-highlighted editing with validation |
| RIS Support | Import/export EndNote and Zotero formats |
| Browser Extensions | Save papers from Safari, Chrome, Firefox, or Edge |
| Keyboard-Driven | Full keyboard navigation and shortcuts |
| Automation API | URL schemes for scripting and AI integration |
| iOS Companion | Full-featured iPhone and iPad app with sync |

## Beta Testing

We're actively developing imbib and welcome beta testers! Join via TestFlight to get early access to new features and help us find bugs before release.

### Join the Beta

📱 **[TestFlight Beta](https://testflight.apple.com/join/XXXXXX)** - Works for both macOS and iOS/iPadOS

### What to Test

- **CloudKit Sync** - Does your library sync correctly between devices?
- **Search Sources** - Do ADS, arXiv, Crossref, etc. return expected results?
- **PDF Management** - Do PDFs download, display, and annotate correctly?
- **Import/Export** - Do BibTeX and RIS files import/export without data loss?

### Reporting Issues

Found a bug or have feedback?

1. **GitHub Issues** (preferred): [Report Issue](https://github.com/yipihey/impress-apps/issues)
2. **TestFlight Feedback**: Shake device or use Help → Send Feedback in the app

Please include:
- What you were doing when the issue occurred
- What you expected vs. what happened
- Your device and OS version

## System Requirements

- **macOS**: 14.0 (Sonoma) or later, Apple Silicon or Intel
- **iOS**: 18.0 or later

## Documentation

Full documentation is available at [yipihey.github.io/impress-apps](https://yipihey.github.io/impress-apps/):

- [Getting Started](https://yipihey.github.io/impress-apps/getting-started)
- [Features](https://yipihey.github.io/impress-apps/features)
- [Keyboard Shortcuts](https://yipihey.github.io/impress-apps/keyboard-shortcuts)
- [Browser Extensions](https://yipihey.github.io/impress-apps/share-extension)
- [Automation API](https://yipihey.github.io/impress-apps/automation)

## Building from Source

**Requires:** Xcode 15+, macOS 14+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
# Install XcodeGen (if not already installed)
brew install xcodegen

# Clone the repository
git clone https://github.com/yipihey/impress-apps.git
cd impress-apps/apps/imbib

# Generate the Xcode project and open it
cd imbib
xcodegen generate
open imbib.xcodeproj
```

In Xcode:
1. Select the **imbib** scheme
2. Select **My Mac** as destination
3. Press **⌘R** to build and run

> **Note**: The `.xcodeproj` is generated from `project.yml` and not stored in git—you must run `xcodegen generate` first.

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed instructions and troubleshooting.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for:

- Detailed build instructions
- Architecture overview
- Coding conventions
- How to add new features

## License

MIT License - see [LICENSE](LICENSE) for details.

---

<p align="center">
  Built by researchers, for researchers.
</p>
