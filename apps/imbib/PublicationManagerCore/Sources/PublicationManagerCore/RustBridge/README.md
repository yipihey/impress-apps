# Rust Bridge Integration Guide

This directory contains the Swift bridge code for integrating the Rust `imbib-core` library.

## Current Status

- **Swift Backend**: ✅ Fully functional
- **Rust Backend**: 🔧 Infrastructure ready, pending library linking

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Code                          │
├─────────────────────────────────────────────────────────────┤
│                 BibTeXParserFactory                          │
│         (Selects backend: .swift or .rust)                  │
├──────────────────────┬──────────────────────────────────────┤
│   BibTeXParser       │         RustBibTeXParser             │
│   (Swift native)     │    (Rust via UniFFI bindings)        │
├──────────────────────┴──────────────────────────────────────┤
│                 BibTeXParsing Protocol                       │
│           (Common interface for both backends)               │
└─────────────────────────────────────────────────────────────┘
```

## Files

- `BibTeXParsingProtocol.swift` - Protocol and factory for parser backends
- `RustBibTeXParser.swift` - Rust-backed implementation (conditionally compiled)

## Enabling the Rust Backend

### 1. Build the Rust Library

```bash
cd imbib-core
cargo build --release --target aarch64-apple-darwin  # macOS
cargo build --release --target aarch64-apple-ios      # iOS device
cargo build --release --target aarch64-apple-ios-sim  # iOS simulator
```

### 2. Generate Swift Bindings

```bash
cargo run --release --bin uniffi-bindgen generate \
    --library target/release/libimbib_core.dylib \
    --language swift \
    --out-dir generated
```

### 3. Link the Library in Xcode

1. Add `libimbib_core.a` to the app target's "Link Binary With Libraries"
2. Add `imbib_core.swift` to the target
3. Add the headers directory to "Header Search Paths"
4. Add `imbib_coreFFI.modulemap` to the target

### 4. Switch to Rust Backend

```swift
// In your app initialization
BibTeXParserFactory.currentBackend = .rust

// Check if Rust is available
if RustLibraryInfo.isAvailable {
    print("Rust version: \(RustLibraryInfo.version)")
}

// Create a parser (uses configured backend)
let parser = BibTeXParserFactory.createParser()
let entries = try parser.parseEntries(bibtexContent)
```

## Performance Comparison

Once both backends are fully integrated, you can benchmark:

```swift
func benchmark() {
    let content = loadLargeBibTeXFile()

    // Swift backend
    BibTeXParserFactory.currentBackend = .swift
    let swiftParser = BibTeXParserFactory.createParser()
    let swiftStart = CFAbsoluteTimeGetCurrent()
    _ = try? swiftParser.parseEntries(content)
    let swiftTime = CFAbsoluteTimeGetCurrent() - swiftStart

    // Rust backend
    BibTeXParserFactory.currentBackend = .rust
    let rustParser = BibTeXParserFactory.createParser()
    let rustStart = CFAbsoluteTimeGetCurrent()
    _ = try? rustParser.parseEntries(content)
    let rustTime = CFAbsoluteTimeGetCurrent() - rustStart

    print("Swift: \(swiftTime)s, Rust: \(rustTime)s")
}
```

## Testing

Run the bridge tests:

```bash
swift test --filter RustBridge
```

## Troubleshooting

### "Cannot find module 'imbib_core'"

The Rust library is not linked. Either:
- Link the library in Xcode (see steps above)
- Or keep using the Swift backend (default)

### Runtime Errors

If you get FFI-related crashes:
1. Ensure the library architecture matches (arm64 vs x86_64)
2. Verify the Swift bindings were generated from the same library version
3. Check that all required frameworks are linked

## Future Work

- [ ] Create XCFramework for easier distribution
- [ ] Add performance benchmarks
- [ ] Support more Rust features (RIS, identifier extraction, deduplication)
