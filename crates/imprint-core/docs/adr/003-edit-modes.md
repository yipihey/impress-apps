# ADR-003: Three Edit Modes

## Status
Accepted

## Context
Academic writers have different preferences and workflows for editing documents:

1. **Code-focused**: Prefer seeing source like a text editor
2. **Output-focused**: Want to see the PDF and click to edit
3. **Hybrid**: Need both source and output visible simultaneously

Desktop real estate varies (laptop vs external monitor), and user expertise ranges from LaTeX experts to collaborators unfamiliar with markup.

## Decision
imprint provides **three distinct edit modes** that users can switch between:

| Mode | Description | Best For |
|------|-------------|----------|
| **DirectPdf** | Full-screen PDF with click-to-edit | Output-focused users, reviewing |
| **SplitView** | Side-by-side source and PDF | Active writing, debugging |
| **TextOnly** | Full-screen source editor | Markup experts, focused writing |

```swift
enum EditMode: String, CaseIterable {
    case directPdf   // PDF dominates, source appears on click
    case splitView   // 50/50 or adjustable split
    case textOnly    // Source dominates, PDF in separate window/tab
}
```

### Mode Behaviors

**DirectPdf Mode**:
- PDF fills the window
- Clicking text opens inline editor at that location
- Changes reflect immediately in PDF
- Outline sidebar for navigation
- Best for: reviewers, final polish, non-technical collaborators

**SplitView Mode**:
- Source editor on left, PDF preview on right
- Synchronized scrolling (optional)
- Cursor position syncs to PDF location
- Adjustable split ratio
- Best for: active writing, equation work, debugging layout

**TextOnly Mode**:
- Full-screen source editor with syntax highlighting
- PDF available in separate window or quick preview panel
- Vim/Helix modal editing fully supported
- Best for: markup experts, distraction-free writing

## Consequences

### Positive
- Accommodates different user preferences
- Smooth onboarding: start with DirectPdf, graduate to TextOnly
- Context-appropriate: different modes for different tasks
- Preserves expert workflows while supporting beginners

### Negative
- Three modes to implement and maintain
- UI complexity in mode switching
- Potential confusion for new users
- State synchronization between modes

## Implementation
- Mode stored per-document in user preferences
- Shared document model across all modes
- Source-to-PDF mapping (SourceMap) enables DirectPdf click-to-edit
- Keyboard shortcut for quick mode switching (Cmd+1/2/3)
