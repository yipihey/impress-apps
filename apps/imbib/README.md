<p align="center">
  <img src="docs/assets/images/logo.png" alt="imbib" width="128" height="128">
</p>

<h1 align="center">imbib</h1>

<p align="center">
  <strong>Subscribe to Science.</strong><br>
  <em>Your research inbox. Every database. One library.</em>
</p>

<p align="center">
  <a href="https://github.com/yipihey/imbib/releases">Download</a> &bull;
  <a href="https://yipihey.github.io/imbib/">Documentation</a> &bull;
  <a href="https://github.com/yipihey/imbib/issues">Report Issue</a>
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

1. Download the latest release from [Releases](https://github.com/yipihey/imbib/releases)
2. Move `imbib.app` to `/Applications`
3. Launch imbib

### iOS

Coming to TestFlight soon.

## Quick Start

1. **Create a library** - Choose a folder for your `.bib` file and PDFs
2. **Search for papers** - Use the search bar (ADS and arXiv enabled by default)
3. **Import papers** - Click to add papers to your library
4. **Attach PDFs** - Drag-and-drop or download from publishers

[Full Getting Started Guide](https://yipihey.github.io/imbib/getting-started)

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

## System Requirements

- **macOS**: 14.0 (Sonoma) or later, Apple Silicon or Intel
- **iOS**: 17.0 or later

## Documentation

Full documentation is available at [yipihey.github.io/imbib](https://yipihey.github.io/imbib/):

- [Getting Started](https://yipihey.github.io/imbib/getting-started)
- [Features](https://yipihey.github.io/imbib/features)
- [Keyboard Shortcuts](https://yipihey.github.io/imbib/keyboard-shortcuts)
- [Browser Extensions](https://yipihey.github.io/imbib/share-extension)
- [Automation API](https://yipihey.github.io/imbib/automation)

## Building from Source

**Requires:** Xcode 15+, macOS 14+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
# Install XcodeGen (if not already installed)
brew install xcodegen

# Clone the repository
git clone https://github.com/yipihey/imbib.git
cd imbib

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
