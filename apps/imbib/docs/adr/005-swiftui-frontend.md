# ADR-005: SwiftUI for Cross-Platform UI

## Status

Accepted

## Date

2026-01-04

## Context

We need a UI framework for both macOS and iOS apps. Options:

1. **SwiftUI** - Apple's declarative UI framework
2. **UIKit/AppKit** - Apple's imperative frameworks (platform-specific)
3. **Catalyst** - Run iPad app on Mac
4. **Cross-platform** - Flutter, React Native, etc.

## Decision

Use **SwiftUI** as the primary UI framework with:
- Shared views in the Core package (70-80%)
- Platform-specific implementations where needed (20-30%)
- `NSViewRepresentable`/`UIViewRepresentable` for PDFKit

## Rationale

### Code Sharing

SwiftUI enables significant code reuse:

```swift
// Shared in Core package - works on both platforms
struct PublicationListView: View {
    @State private var viewModel: LibraryViewModel
    
    var body: some View {
        List(viewModel.publications) { pub in
            PublicationRow(publication: pub)
        }
    }
}
```

### Claude Code Proficiency

SwiftUI has extensive training data:
- Apple documentation and tutorials
- WWDC session transcripts
- Open source examples
- Stack Overflow discussions

Claude Code generates reliable SwiftUI consistently.

### Modern Features

SwiftUI provides:
- `NavigationSplitView` for three-column layouts
- `@Observable` macro for clean state management
- Built-in animations and transitions
- Automatic Dark Mode support
- Accessibility by default

### Platform Adaptation

`NavigationSplitView` adapts automatically:
- **macOS**: Three-column layout
- **iPad landscape**: Two or three columns
- **iPad portrait/iPhone**: Stack navigation

## Implementation

### Navigation Structure

```swift
struct MainView: View {
    @State private var selectedCollection: Collection?
    @State private var selectedPublication: Publication?
    
    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedCollection)
        } content: {
            PublicationListView(
                collection: selectedCollection,
                selection: $selectedPublication
            )
        } detail: {
            if let publication = selectedPublication {
                PublicationDetailView(publication: publication)
            } else {
                ContentUnavailableView("Select a Publication", systemImage: "doc")
            }
        }
    }
}
```

### Platform Abstraction

For platform-specific features, use protocols:

```swift
// Protocol in Core package
protocol PDFViewing: View {
    init(url: URL)
}

// macOS implementation
#if os(macOS)
struct PDFViewer: PDFViewing {
    let url: URL
    
    var body: some View {
        PDFKitView(url: url)
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL
    
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        return view
    }
}
#endif

// iOS implementation
#if os(iOS)
struct PDFViewer: PDFViewing {
    let url: URL
    
    var body: some View {
        PDFKitView(url: url)
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        return view
    }
}
#endif
```

### ViewModifiers for Differences

```swift
struct PlatformStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .frame(minWidth: 800, minHeight: 600)
        #else
        content
        #endif
    }
}

extension View {
    func platformStyle() -> some View {
        modifier(PlatformStyle())
    }
}
```

## Consequences

### Positive

- 70-80% code sharing between platforms
- Modern, maintainable codebase
- Automatic platform adaptation
- Strong Claude Code support
- Rapid iteration with previews

### Negative

- Some macOS features require AppKit interop
- PDFKit requires representable wrappers
- Complex windowing needs AppKit (multi-window, panels)
- iOS 17/macOS 14 minimum for best features

### Mitigations

- Use `NSViewRepresentable` for PDFKit
- Accept iOS 17/macOS 14 minimum (reasonable for new app)
- Defer complex windowing to later versions

## Alternatives Considered

### UIKit + AppKit

Would require two separate UI codebases. Rejected for maintenance burden.

### Catalyst

macOS Catalyst apps feel like iPad apps on Mac, not native Mac apps. Our three-column layout needs proper macOS behavior.

### Flutter/React Native

Would lose:
- Native performance
- Deep OS integration (Spotlight, Shortcuts, CloudKit)
- PDFKit access
- App Store optimization

Not appropriate for a native-feeling productivity app.
