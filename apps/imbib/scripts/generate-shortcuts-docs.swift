#!/usr/bin/env swift
//
//  generate-shortcuts-docs.swift
//  imbib
//
//  Generates keyboard-shortcuts.md from KeyboardShortcutsSettings.swift
//
//  Run: swift scripts/generate-shortcuts-docs.swift > docs/keyboard-shortcuts-generated.md
//
//  This script parses the KeyboardShortcutBinding definitions and outputs
//  a formatted markdown table grouped by category.
//
//  NOTE: The source of truth is KeyboardShortcutsSettings.defaults in Swift.
//  This script extracts that data for documentation purposes.
//

import Foundation

// MARK: - Shortcut Data Structures

struct ShortcutInfo {
    let id: String
    let displayName: String
    let category: String
    let shortcut: String
}

// MARK: - Modifier Symbol Mapping

let modifierSymbols: [String: String] = [
    ".command": "⌘",
    ".shift": "⇧",
    ".option": "⌥",
    ".control": "⌃"
]

// MARK: - Special Key Symbol Mapping

let specialKeySymbols: [String: String] = [
    ".return": "↩",
    ".escape": "⎋",
    ".delete": "⌫",
    ".tab": "⇥",
    ".space": "Space",
    ".upArrow": "↑",
    ".downArrow": "↓",
    ".leftArrow": "←",
    ".rightArrow": "→",
    ".home": "↖",
    ".end": "↘",
    ".pageUp": "⇞",
    ".pageDown": "⇟",
    ".plus": "+",
    ".minus": "-"
]

// MARK: - Parsing Functions

/// Parse a key definition like `.character("k")` or `.special(.downArrow)`
func parseKey(_ keyString: String) -> String {
    let trimmed = keyString.trimmingCharacters(in: .whitespaces)

    if trimmed.contains(".character(") {
        // Extract character from .character("x") or .character("\\")
        // Handle escaped backslash specially
        if trimmed.contains("\"\\\\\"") || trimmed.contains("\"\\\"") {
            return "\\"
        }
        // Standard character extraction
        if let range = trimmed.range(of: #"\"(.)\""#, options: .regularExpression) {
            var char = String(trimmed[range])
            char = char.replacingOccurrences(of: "\"", with: "")
            return char.uppercased()
        }
        // Fallback: extract any single character between quotes
        if let start = trimmed.firstIndex(of: "\""),
           let end = trimmed.lastIndex(of: "\""),
           start < end {
            let charStart = trimmed.index(after: start)
            let extracted = String(trimmed[charStart..<end])
            if extracted == "\\" || extracted == "\\\\" {
                return "\\"
            }
            return extracted.uppercased()
        }
    } else if trimmed.contains(".special(") {
        // Extract special key
        for (key, symbol) in specialKeySymbols {
            if trimmed.contains(key) {
                return symbol
            }
        }
    }
    return trimmed
}

/// Parse modifiers like `.command` or `[.shift, .command]`
func parseModifiers(_ modString: String) -> String {
    let trimmed = modString.trimmingCharacters(in: .whitespaces)

    // Handle .none case
    if trimmed == ".none" {
        return ""
    }

    // For shift-only modifier, use "Shift+" for readability
    if trimmed == ".shift" {
        return "Shift+"
    }

    // Order: control, option, shift, command (standard macOS order)
    var result = ""

    if trimmed.contains(".control") { result += "⌃" }
    if trimmed.contains(".option") { result += "⌥" }
    if trimmed.contains(".shift") { result += "⇧" }
    if trimmed.contains(".command") { result += "⌘" }

    return result
}

/// Parse a category name
func parseCategory(_ catString: String) -> String {
    let trimmed = catString.trimmingCharacters(in: .whitespaces)

    let categoryMap: [String: String] = [
        ".navigation": "Navigation",
        ".views": "Views",
        ".focus": "Focus",
        ".paperActions": "Paper Actions",
        ".clipboard": "Clipboard",
        ".filtering": "Filtering",
        ".inboxTriage": "Inbox Triage",
        ".pdfViewer": "PDF Viewer",
        ".fileOperations": "File Operations",
        ".app": "App"
    ]

    return categoryMap[trimmed] ?? trimmed
}

// MARK: - Main Script

// Find the source file
let scriptDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
let projectRoot = scriptDir.deletingLastPathComponent()
let sourceFile = projectRoot
    .appendingPathComponent("PublicationManagerCore")
    .appendingPathComponent("Sources")
    .appendingPathComponent("PublicationManagerCore")
    .appendingPathComponent("Settings")
    .appendingPathComponent("KeyboardShortcutsSettings.swift")

guard FileManager.default.fileExists(atPath: sourceFile.path) else {
    fputs("Error: Cannot find KeyboardShortcutsSettings.swift at \(sourceFile.path)\n", stderr)
    exit(1)
}

guard let content = try? String(contentsOf: sourceFile, encoding: .utf8) else {
    fputs("Error: Cannot read KeyboardShortcutsSettings.swift\n", stderr)
    exit(1)
}

// Parse KeyboardShortcutBinding definitions
var shortcuts: [ShortcutInfo] = []

// Multi-line regex to match KeyboardShortcutBinding initializers
// Handles both single modifiers (.command) and arrays ([.shift, .command])
// Also handles .none for modifiers
let pattern = #"KeyboardShortcutBinding\(\s*id:\s*"([^"]+)",\s*displayName:\s*"([^"]+)",\s*category:\s*(\.[a-zA-Z]+),\s*key:\s*([^,]+),\s*modifiers:\s*(\[[^\]]+\]|\.[a-zA-Z]+),"#

let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
let range = NSRange(content.startIndex..., in: content)

regex.enumerateMatches(in: content, options: [], range: range) { match, _, _ in
    guard let match = match else { return }

    let idRange = Range(match.range(at: 1), in: content)!
    let nameRange = Range(match.range(at: 2), in: content)!
    let categoryRange = Range(match.range(at: 3), in: content)!
    let keyRange = Range(match.range(at: 4), in: content)!
    let modifiersRange = Range(match.range(at: 5), in: content)!

    let id = String(content[idRange])
    let displayName = String(content[nameRange])
    let category = parseCategory(String(content[categoryRange]))
    let key = parseKey(String(content[keyRange]))
    let modifiers = parseModifiers(String(content[modifiersRange]))

    let shortcut = modifiers + key

    shortcuts.append(ShortcutInfo(
        id: id,
        displayName: displayName,
        category: category,
        shortcut: shortcut
    ))
}

// Group by category
let categoryOrder = [
    "Navigation",
    "Views",
    "Focus",
    "Paper Actions",
    "Clipboard",
    "Filtering",
    "Inbox Triage",
    "PDF Viewer",
    "File Operations",
    "App"
]

var groupedShortcuts: [String: [ShortcutInfo]] = [:]
for shortcut in shortcuts {
    groupedShortcuts[shortcut.category, default: []].append(shortcut)
}

// Generate markdown
print("""
---
layout: default
title: Keyboard Shortcuts
nav_order: 5
---

# Keyboard Shortcuts

imbib provides extensive keyboard shortcuts for efficient paper management.

{: .note }
> **Vim-style navigation**: Use `j`/`k` for down/up, `h`/`l` for previous/next tab.
> **Single-key shortcuts** (in Inbox Triage) only work when the Inbox is focused.

---

""")

for category in categoryOrder {
    guard let categoryShortcuts = groupedShortcuts[category], !categoryShortcuts.isEmpty else {
        continue
    }

    print("## \(category)")
    print()
    print("| Action | Shortcut |")
    print("|--------|----------|")

    for shortcut in categoryShortcuts {
        // Escape backslash for markdown
        let escapedShortcut = shortcut.shortcut.replacingOccurrences(of: "\\", with: "`\\`")
        print("| \(shortcut.displayName) | \(escapedShortcut) |")
    }

    print()
}

// Add iOS-specific shortcuts section (hardcoded since not in KeyboardShortcutsSettings)
print("""
---

## iOS Keyboard Shortcuts (iPad)

These shortcuts are available when using a hardware keyboard with iPad:

### PDF Annotations

| Action | Shortcut |
|--------|----------|
| Highlight | H |
| Underline | U |
| Strikethrough | S |
| Add Note | N |
| Draw/Sketch | D |

### Notes Editor

| Action | Shortcut |
|--------|----------|
| Save notes | ⌘S |
| Bold | ⌘B |
| Italic | ⌘I |
| Undo | ⌘Z |
| Redo | ⇧⌘Z |

---

## Apple Pencil Gestures (iPad)

imbib supports Apple Pencil with Scribble for natural text input:

| Gesture | Action |
|---------|--------|
| Write | Insert text at cursor |
| Scratch out | Delete text |
| Circle | Select word |
| Tap and hold | Position cursor |

---

## Customizing Shortcuts

Keyboard shortcuts can be customized in **Settings > Keyboard Shortcuts** (macOS) or **Settings > Keyboard** (iPad).

---

*Auto-generated from `KeyboardShortcutsSettings.defaults` — the single source of truth.*

Last updated: \(ISO8601DateFormatter().string(from: Date()))
""")
