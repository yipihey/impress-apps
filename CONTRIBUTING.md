# Contributing to impress-apps

Thank you for your interest in contributing to the impress suite of academic productivity apps.

## Repository Structure

This is a monorepo containing:

- **crates/**: Shared Rust libraries (13 crates)
- **apps/**: SwiftUI applications (imbib, imprint, implore, impel-tui)
- **packages/**: Shared Swift packages

## Getting Started

### Prerequisites

- **Rust**: Install via [rustup](https://rustup.rs/)
- **Xcode 15+**: For building Swift/SwiftUI apps (macOS only)
- **XcodeGen**: For generating Xcode projects (`brew install xcodegen`)

### Building Rust Crates

```bash
# Check all crates compile
cargo check

# Run all tests
cargo test

# Build specific crate
cargo build -p imbib-core
```

### Building Swift Apps

Each app in `apps/` uses XcodeGen. For example, to build imbib:

```bash
cd apps/imbib/imbib
xcodegen generate
open imbib.xcodeproj
```

See each app's README for specific instructions.

## Development Workflow

1. **Fork and clone** the repository
2. **Create a branch** for your feature or fix
3. **Make your changes** following our conventions
4. **Run tests**: `cargo test` for Rust, Xcode tests for Swift
5. **Submit a pull request** with a clear description

## Code Style

### Rust

- Follow standard Rust conventions (use `cargo fmt` and `cargo clippy`)
- Document public APIs with doc comments
- Write tests for new functionality

### Swift

- Follow Swift API Design Guidelines
- Use SwiftUI for new UI code
- See app-specific CONVENTIONS.md files for details

## Architecture Decision Records

Significant design decisions are documented as ADRs:

- `apps/imbib/docs/adr/` - imbib decisions
- `crates/impel-core/docs/adr/` - impel decisions

Consider adding an ADR for architectural changes.

## App-Specific Guides

| App | Contributing Guide |
|-----|-------------------|
| imbib | [apps/imbib/CONTRIBUTING.md](apps/imbib/CONTRIBUTING.md) |
| imprint | See apps/imprint/README.md |
| implore | See apps/implore/README.md |

## Reporting Issues

- Use GitHub Issues for bug reports and feature requests
- Include reproduction steps and environment details
- Check existing issues before creating new ones

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
