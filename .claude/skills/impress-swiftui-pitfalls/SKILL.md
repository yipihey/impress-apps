---
name: impress-swiftui-pitfalls
description: Hard-won regression traps from the impress-apps codebase — SwiftUI + Swift concurrency + AppKit-bridging gotchas that have already caused real bugs and slow debug cycles. Use when editing any macOS/iOS view in imbib, imprint, implore, impel, or impart, especially when adding async work, text-input handling, split-view layouts, NSViewRepresentable wrappers, or background services. Complements (does NOT duplicate) the generic `swiftui-expert-skill`.
---

# impress-apps SwiftUI / concurrency pitfalls

Generic SwiftUI guidance lives in `swiftui-expert-skill`. This skill is the project-specific lessons-learned layer — each rule corresponds to a bug we shipped, debugged, and would otherwise re-ship.

When you touch code matching any of the triggers, scan the relevant rule below before writing.

---

## 1. `@State` capture before async work

**Trigger:** any `Task { ... }` body that reads `@State`, `@Binding`, or any SwiftUI property wrapper.

**Rule:** Capture into a local `let` BEFORE the `Task` body.

```swift
// CORRECT
let targetIDs = self.targetIDs
Task {
    for id in targetIDs { ... }  // captured snapshot
}

// WRONG — Task captures a reference into heap-backed @State storage.
// Another view (overlay dismissing, sheet binding resetting) can
// clear that storage before the Task body runs, leaving you with []
Task {
    for id in self.targetIDs { ... }
}
```

**Why:** SwiftUI `@State` is heap-backed. `Task { }` captures a reference, not a value. Bug we hit: tags applied to 0 publications because the overlay had cleared `tagTargetIDs` between the user click and the Task body running. Visible only via the three-point trace logging (see rule 4).

## 2. Coordinator's `parent` is stale unless you refresh it

**Trigger:** any `NSViewRepresentable` / `UIViewRepresentable` whose `Coordinator` reads `parent.*` in delegate callbacks (`textDidChange`, `tableView(_:didSelect:)`, etc.).

**Rule:** `context.coordinator.parent = self` as the first line of `updateNSView` / `updateUIView`.

```swift
func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.parent = self  // ← required
    // ... rest
}
```

**Why:** `Coordinator.parent` is captured ONCE in `init`. SwiftUI re-creates the struct on every body re-eval; without this assignment, delegate callbacks read STALE bindings forever. Bug we hit: imprint's syntax highlighter dispatched to the typst tokenizer for every keystroke on a `.tex` document, because the coordinator's `parent.syntaxMode` was frozen at `.typst` (the struct default). LaTeX commands turned red mid-edit.

## 3. `@ViewBuilder` + `(some View)?` does NOT reliably return nil

**Trigger:** any computed view property declared as `(some View)?` with `@ViewBuilder`, intended to return `nil` for some cases.

**Rule:** Don't. Use a sibling `Bool` to gate, and let the view-builder return plain `some View`.

```swift
// CORRECT
var body: some View {
    if isJournalTab { journalDispatch } else { fallback }
}
private var isJournalTab: Bool {
    switch viewModel.selectedTab {
    case .journalAll, .journalByStatus, .journalSubmissions, .manuscript:
        return true
    default: return false
    }
}
@ViewBuilder
private var journalDispatch: some View { /* switch ... */ }

// WRONG — `nil as EmptyView?` in default case does NOT propagate through
// `if let` reliably. Non-journal tabs ALSO render the empty branch,
// hiding the real fallback content (list, toolbar, everything).
@ViewBuilder
private var journalDispatch: (some View)? {
    switch viewModel.selectedTab {
    case .journalAll: JournalManuscriptsListView()
    default: nil as EmptyView?
    }
}
```

**Why:** `@ViewBuilder` unifies branches into an opaque conditional content type. The `nil as EmptyView?` in the default arm has the right STATIC type but doesn't propagate as `nil` through `if let`. Bug we hit (in this session): imbib showed only the sidebar — no list, no detail, no toolbar — because every non-journal tab also matched the journal branch.

## 4. HSplitView at the top of a DocumentGroup / ZStack must declare a fill frame

**Trigger:** replacing `NavigationSplitView` with a top-level `HSplitView` inside a `DocumentGroup`, a `WindowGroup`, or a `ZStack`.

**Rule:** Add `.frame(maxWidth: .infinity, maxHeight: .infinity)` to the HSplitView itself, AND to each switch branch of mode-content children. NavigationSplitView fills automatically — HSplitView does not.

```swift
HSplitView {
    sidebar
    switch mode {
    case .textOnly: editor.frame(maxWidth: .infinity, maxHeight: .infinity)
    case .splitView: splitView.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
```

**Why:** Without these frames, HSplitView collapses to children's intrinsic size. The parent ZStack centers the small strip vertically, leaving large empty bands above and below. Bug we hit (this session): imprint's editor showed as a thin strip in the middle of the window with the toolbar floating above and white space below.

## 5. Don't intercept unmodified character keys outside text-aware guards

**Trigger:** any view registering `.onKeyPress { ... }` that matches `j`, `k`, `h`, `l`, `s`, `d`, etc. (unmodified character keys we use for vim-style nav).

**Rule:** Use `.keyboardGuarded { press in ... }` from `ImpressKeyboard` instead. It checks `TextFieldFocusDetection.isTextFieldFocused()` so the shortcut doesn't fire while the user is typing in a TextField / TextEditor / search field.

```swift
// CORRECT
.keyboardGuarded { press in
    if press.characters == "j" { down(); return .handled }
    return .ignored
}

// WRONG — steals the keystroke from any focused TextEditor
.onKeyPress { press in
    if press.characters == "j" { down(); return .handled }
    return .ignored
}
```

**Special case:** Don't put `.focusable()` on a parent of an `NSViewRepresentable`-wrapped text editor (`HelixTextView`, etc.). The SwiftUI `.focusable()` wrapper can intercept keys before the AppKit responder chain even when `.keyboardGuarded` returns `.ignored`. Place `.focusable().keyboardGuarded` on the outermost container only.

**`.onKeyPress` IS still fine when:** matching only special keys (Escape, Return, arrows), modified keys (Cmd+1), or inside self-managed focus components.

## 6. Background services must defer their first work cycle ≥ 60s after launch

**Trigger:** any service that calls `RustStoreAdapter.shared.didMutate()` (or posts `.storeDidMutate`, or otherwise triggers a publication-store invalidation) on a timer / schedule.

**Rule:** The first work cycle of any such service must wait 60–90 seconds after launch. AND: never use `try? await Task.sleep` inside a `for` loop — `try?` swallows `CancellationError` so the loop runs unkillably.

```swift
// CORRECT
try? await Task.sleep(for: .seconds(90))  // single sleep, cancellable
// ... start work

// WRONG — uncancellable; ten 9s sleeps cannot be killed by Task.cancel()
for _ in 0..<10 {
    try? await Task.sleep(for: .seconds(9))
}
```

**Why:** During the first ~90s of app launch, UI is still settling. Any `.storeDidMutate` triggers a SwiftUI body re-eval; with two `ShareLink`s in the toolbar this re-creates `SHKSharingServicePicker`s, which logs and (worse) reflows the window. A loop of these creates a perpetual render loop — the famous spinning beach ball. Detection: `log show --process imbib --last 15s | grep -c SHKSharingServicePicker` after 90s should be 0.

## 7. Three-point trace whenever you touch persistence

**Trigger:** any feature that mutates Core Data, the Rust SharedStore, UserDefaults, or files used as persistence.

**Rule:** Add `*Capture()` log lines at THREE points:

```swift
Logger.library.infoCapture("Applying tag '\(tagPath)' to \(pubIDs.count) pubs", category: "tags")
// ... mutate ...
Logger.library.infoCapture("Save: context.hasChanges = \(context.hasChanges)", category: "tags")
// ... rebuild ...
Logger.library.infoCapture("Display: \(taggedCount) rows now show tags", category: "tags")
```

**Why:** Mutation, save, and display are independent failure modes. The "applying to 0 pubs" line is what catches the @State-capture bug from rule 1 — without all three points you debug for hours.

Logs surface at `http://localhost:23120/api/logs?category=tags` (imbib) and in the in-app console window (Cmd+Shift+C). Every impress app has this — use it.

## 8. Core Data to-many mutations need `mutableSetValue(forKey:)`

**Trigger:** any code that adds/removes to a Core Data to-many relationship (tags, authors, collections, etc.) — `imbib` only.

**Rule:**

```swift
// CORRECT — Core Data change-tracking sees individual ops
let tagSet = publication.mutableSetValue(forKey: "tags")
tagSet.add(tag)

// WRONG — Core Data may not detect the swap reliably, especially
// across actor boundaries or with CloudKit containers
var tags = publication.tags ?? []
tags.insert(tag)
publication.tags = tags
```

## 9. macOS toolbar inside `NavigationSplitView` detail + nested `HSplitView` — don't try to right-align

**Trigger:** adding toolbar items to a view that uses `NavigationSplitView { } detail: { HSplitView { ... } }` (imbib's main view).

**Rule:** Accept that `.primaryAction` items cluster on the left next to `.navigation` items. Don't try `Spacer()`, `.frame(maxWidth: .infinity)`, `.principal`, or `.safeAreaInset(edge: .top)` — every approach failed. The proven pattern (imbib's `SectionContentView`):

1. All detail items in `.toolbar { ToolbarItem(placement: .primaryAction) { ... } }` (they cluster on the left — accept it).
2. `.ignoresSafeArea(.container, edges: .top)` on the detail ZStack — reclaims the dead space above the content.
3. `.padding(.top, 40)` on the first content element of each detail tab so content can scroll up under the toolbar without being initially obscured.

Read root `CLAUDE.md` § "macOS Toolbar & Split View Layout" for the failed-approaches table before touching the toolbar.

---

## Quick checklist before committing a SwiftUI change

- [ ] Any `Task { }` in a button / async handler reads `@State` via a local `let`?
- [ ] Any `NSViewRepresentable` I touched has `context.coordinator.parent = self` in `updateNSView`?
- [ ] Any new `@ViewBuilder` that returns `(some View)?` — refactor to `Bool` guard + plain `some View`.
- [ ] New HSplitView at the top of a window has `.frame(maxWidth: .infinity, maxHeight: .infinity)` on the outer + each child?
- [ ] Any new `.onKeyPress { }` matches unmodified chars — switch to `.keyboardGuarded { }`.
- [ ] Any new background timer / scheduler defers its first cycle ≥ 60s + uses a single `try? await Task.sleep` (not a loop)?
- [ ] Persistence mutation has the three-point log trace?
- [ ] Core Data to-many mutation uses `mutableSetValue(forKey:)`?

If anything in this list is violated, fix it before the user has to find the bug in production.
