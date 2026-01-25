#!/usr/bin/env swift
//
//  generate-shortcuts-docs.swift
//  imbib
//
//  Generates keyboard-shortcuts.md from KeyboardShortcutsSettings.swift
//  Run: swift scripts/generate-shortcuts-docs.swift > docs/keyboard-shortcuts.md
//
//  This script parses the KeyboardShortcutBinding definitions and outputs
//  a formatted markdown table grouped by category.
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
    if keyString.contains(".character(") {
        // Extract character from .character("x")
        if let match = keyString.range(of: #"\"(.)\""#, options: .regularExpression) {
            let char = String(keyString[match]).replacingOccurrences(of: "\"", with: "")
            return char.uppercased()
        }
    } else if keyString.contains(".special(") {
        // Extract special key
        for (key, symbol) in specialKeySymbols {
            if keyString.contains(key) {
                return symbol
            }
        }
    }
    return keyString
}

/// Parse modifiers like `.command` or `[.shift, .command]`
func parseModifiers(_ modString: String) -> String {
    // Order: control, option, shift, command (standard macOS order)
    var result = ""

    if modString.contains(".control") { result += "⌃" }
    if modString.contains(".option") { result += "⌥" }
    if modString.contains(".shift") { result += "⇧" }
    if modString.contains(".command") { result += "⌘" }

    return result
}

/// Parse a category name
func parseCategory(_ catString: String) -> String {
    // Remove the leading dot and convert to display format
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

// Regex to match KeyboardShortcutBinding initializers
// Handle both single modifiers (.command) and arrays ([.shift, .command])
let pattern = #"KeyboardShortcutBinding\(\s*id:\s*"([^"]+)",\s*displayName:\s*"([^"]+)",\s*category:\s*(\.\w+),\s*key:\s*([^,]+),\s*modifiers:\s*(\[[^\]]+\]|\.[a-zA-Z]+),"#

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

imbib provides extensive keyboard shortcuts for efficient paper management. This page is auto-generated from the source code.

{: .note }
> Single-key shortcuts (K, D, R, U, J, O) only work when the Inbox is focused and no text field has focus.

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
        print("| \(shortcut.displayName) | \(shortcut.shortcut) |")
    }

    print()
}

print("""
---

*This documentation was auto-generated from `KeyboardShortcutsSettings.swift`.*
""")
