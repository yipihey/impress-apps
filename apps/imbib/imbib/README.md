# imbib macOS App

This directory contains the macOS app shell for imbib.

## Setup Instructions

1. **Create Xcode Project**:
   - Open Xcode
   - File → New → Project
   - Choose macOS → App
   - Product Name: `imbib`
   - Team: Your development team
   - Organization Identifier: `com.yourorg`
   - Interface: SwiftUI
   - Language: Swift
   - Storage: None (we use Core Data from the package)
   - Include Tests: Yes

2. **Add PublicationManagerCore Package**:
   - File → Add Package Dependencies
   - Click "Add Local..."
   - Navigate to `../PublicationManagerCore`
   - Add the package

3. **Replace Generated Files**:
   - Delete the auto-generated `imbibApp.swift` and `ContentView.swift`
   - Drag the `imbib/` source folder into your project
   - When prompted, select "Create folder references"

4. **Configure Entitlements**:
   - Copy `Resources/imbib.entitlements` to your project
   - In Build Settings, set "Code Signing Entitlements" to point to this file

5. **Configure Build Settings**:
   - Deployment Target: macOS 14.0
   - Swift Language Version: Swift 5.9
   - Strict Concurrency Checking: Complete

## Directory Structure

```
imbib/
├── imbibApp.swift           # App entry point
├── ContentView.swift        # Main NavigationSplitView
├── Views/
│   ├── Sidebar/
│   │   └── SidebarView.swift
│   ├── Library/
│   │   └── LibraryListView.swift
│   ├── Detail/
│   │   └── PublicationDetailView.swift
│   ├── Search/
│   │   └── SearchView.swift
│   └── Settings/
│       └── SettingsView.swift
├── Platform/                 # macOS-specific code
│   └── (PDFViewer, etc.)
└── Resources/
    └── imbib.entitlements
```

## Building

```bash
# Build from command line (after Xcode project is set up)
xcodebuild -project imbib.xcodeproj -scheme imbib -configuration Debug build
```

## Requirements

- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- Swift 5.9+
