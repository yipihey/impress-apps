// Persistence SEAM file — CROSS-PLATFORM (macOS + iOS).
//
//  StoreKernelScope.swift
//  PublicationManagerCore
//
//  Stage 4b: the three host hooks a GENERIC store kernel needs, so the kernel
//  itself can stop naming one app's singletons.
//
//  Before this file, the two generic store kernels in the suite — the
//  collection kernel (`CollectionStoreAdapter`) and the triage kernel (the
//  store half of `RecordTriageActions.storeBacked`) — hard-coded THREE imbib
//  facts each:
//
//    1. which `SharedStore` handle to talk to (their own, opened on
//       `SharedWorkspace.databasePath`),
//    2. how to announce a mutation (`RustStoreAdapter.shared.noteExternalMutation`
//       / `RustStoreAdapter.shared.didMutate`),
//    3. where undo goes (`UndoCoordinator.shared`, a macOS singleton).
//
//  Any of the three is enough to keep a sibling app off the kernel: imprint
//  reaching for `RustStoreAdapter.shared` would boot a SECOND store facade
//  (imbib's) inside imprint, and reaching for `UndoCoordinator.shared` would
//  re-pin the code to macOS. That is exactly why
//  `apps/imprint/Shared/Services/ManuscriptStoreAdapter.swift` grew a hand-rolled
//  twin of both kernels — ~540 lines whose own comments admitted they were a
//  copy ("the record-kind contract, read (not retyped)", "Mirrors
//  `CollectionStoreAdapter`'s three rules").
//
//  A scope is those three facts, injected. imbib's scope is the historical
//  behaviour verbatim; imprint's points at its own store handle, its own
//  `postMutation` fan-out and a caller-supplied `UndoManager` (the macOS window's
//  on macOS, `SceneUndoManager.shared.manager` on iOS, a fresh one in tests).
//

import Foundation
import ImpressRustCore
import ImpressStoreKit

// MARK: - Undo action names

/// Every undo action name the generic store kernels register, in ONE place.
///
/// Top-level (not nested inside a `@MainActor` kernel) so a host can read the
/// strings from any isolation — which is the point: imprint's
/// `ManuscriptStoreAdapter.UndoActionName` now READS these instead of restating
/// them, the same way it reads its status lifecycle off the record-kind
/// descriptor. A second literal is a second source of truth, and these strings
/// are what the Edit menu says out loud.
///
/// The collection names are the Rust `undo_description` strings the delegated
/// `UndoInfo`s carried — a `SetPayload("name")` reads "Edit name", not "Rename
/// Folder". Renaming any of them to folder prose is a deliberate UX change for
/// another pass, not a side effect of a dedup.
public enum StoreKernelUndoAction {

    // Collections (`CollectionStoreAdapter`)

    /// imbib's sidebar has never registered a create inverse; imprint has,
    /// under this string, since it hand-rolled the kernel.
    public static let createCollection = "New Folder"
    public static let renameCollection = "Edit name"
    public static let reorderCollection = "Edit sort_order"
    public static let reparentCollection = "Move Folder"
    public static let deleteCollection = "Delete"
    public static let addMembers = "Add to Collection"
    public static let removeMembers = "Remove from Collection"

    // Triage (`RecordTriageStoreKernel`)

    public static let star = "Star"
    public static let flag = "Flag"
    public static let addTag = "Add Tag"
    public static let removeTag = "Remove Tag"
    public static let dismiss = "Dismiss"
    public static let restore = "Restore"
    public static let archive = "Archive"
    public static let rename = "Rename"
    /// Fallback for a `setStatus` call that names no action of its own.
    public static let changeStatus = "Change Status"
}

// MARK: - Mutation notice

/// How a generic store kernel tells its host that the store changed.
///
/// The signature is deliberately the intersection of the two fan-out calls that
/// existed before it — `RustStoreAdapter.noteExternalMutation(structural:affectedIDs:kind:)`
/// and imprint's private `didMutate(structural:affectedIDs:kind:)` — so each
/// host can pass its own method reference and the events stay byte-identical to
/// what the code being replaced posted.
public typealias StoreMutationNotice =
    @MainActor (_ structural: Bool, _ affectedIDs: Set<UUID>?, _ kind: MutationKind?) -> Void

// MARK: - Undo scope

/// Where a generic store verb registers its undo entry.
///
/// The two cases are the two undo plumbings the suite actually has, and they
/// are NOT interchangeable — which is why this is an enum and not an
/// `UndoManager?`:
///
/// - `.coordinator` goes through imbib's `UndoCoordinator`, which also records
///   the action to the Undo History panel (`UndoHistoryStore`) and calls
///   `didUndo()` as each entry fires. macOS-only in practice because that is
///   where the panel lives.
/// - `.manager` registers against a plain Foundation `UndoManager` the CALLER
///   supplies, with no history panel. This is imprint's plumbing (an iOS view
///   passes the responder chain's manager, a macOS view can pass the window's,
///   a test passes its own).
///
/// `.disabled` registers nothing — the default for verbs whose historical
/// behaviour was not undoable, so migrating a call site onto a kernel never
/// silently ADDS an Edit-menu entry.
public enum StoreUndoScope {
    /// imbib's `UndoCoordinator.shared` (records to the Undo History panel).
    case coordinator
    /// A caller-supplied `UndoManager` — imprint and tests. `nil` is a no-op.
    case manager(UndoManager?)
    /// Register nothing.
    case disabled
}

extension StoreUndoScope {

    /// Whether a registration would actually land anywhere. Lets a kernel skip
    /// the prior-value reads an undo entry needs when nobody is listening.
    public var isActive: Bool {
        switch self {
        case .coordinator: return true
        case .manager(let manager): return manager != nil
        case .disabled: return false
        }
    }

    /// Register a self-inverting pair. Undoing runs `undo` and re-registers the
    /// mirror; because that registration happens WHILE the manager is undoing,
    /// `UndoManager` puts it on the redo stack — so ⌘Z/⌘⇧Z alternate
    /// indefinitely from a single call here.
    ///
    /// The `.manager` body is `ManuscriptStoreAdapter.registerReversible`
    /// verbatim, including the `MainActor.assumeIsolated` (NOT a `Task`):
    /// `NSUndoManager` routes registrations made DURING an undo to the redo
    /// stack, so deferring the re-registration runs it after `undo()` has
    /// returned, landing the redo on the UNDO stack — ⌘Z then toggles instead
    /// of ⌘⇧Z advancing. That regression has shipped once already; see
    /// `UndoCoordinator.registerUndo(info:)`'s comment.
    @MainActor
    public func registerReversible(
        target: AnyObject?,
        actionName: String,
        undo: @escaping @MainActor () -> Void,
        redo: @escaping @MainActor () -> Void
    ) {
        switch self {
        case .disabled:
            return
        case .coordinator:
            UndoCoordinator.shared.registerUndoClosure(
                actionName: actionName, undo: undo, redo: redo)
        case .manager(let undoManager):
            guard let undoManager, let target else { return }
            undoManager.registerUndo(withTarget: target) { [weak undoManager] recovered in
                MainActor.assumeIsolated {
                    undo()
                    StoreUndoScope.manager(undoManager).registerReversible(
                        target: recovered, actionName: actionName, undo: redo, redo: undo)
                }
            }
            undoManager.setActionName(actionName)
        }
    }
}

// MARK: - Scope

/// The host-supplied hooks a generic store kernel runs on: which store handle,
/// how to announce a mutation, where undo goes, and what object undo
/// registrations are made against.
///
/// `undoTarget` is `weak` on purpose. `UndoManager.registerUndo(withTarget:)`
/// keys its entries by target, and `removeAllActions(withTarget:)` purges by
/// the same key — so the target must stay the host adapter (which is what
/// imprint registered against before this seam existed), not a shared token
/// that would make one adapter's purge clear another's stack.
@MainActor
public struct StoreKernelScope {

    /// The impress-core handle every verb reads and writes through. `nil` means
    /// the host failed to open the store; every kernel verb then no-ops (the
    /// behaviour `CollectionStoreAdapter` has always had via `guard let store`).
    public let store: SharedStore?

    /// The object undo entries are registered against.
    public weak var undoTarget: AnyObject?

    /// Fan-out for "the store changed".
    public let noteMutation: StoreMutationNotice

    /// Where undo goes when a verb is called without an explicit scope.
    public var defaultUndo: StoreUndoScope

    public init(
        store: SharedStore?,
        undoTarget: AnyObject?,
        defaultUndo: StoreUndoScope = .disabled,
        noteMutation: @escaping StoreMutationNotice
    ) {
        self.store = store
        self.undoTarget = undoTarget
        self.defaultUndo = defaultUndo
        self.noteMutation = noteMutation
    }

    /// Register a reversible pair against this scope's target, honouring the
    /// per-call scope when one is given and falling back to `defaultUndo`.
    public func registerReversible(
        _ undoScope: StoreUndoScope?,
        actionName: String,
        undo: @escaping @MainActor () -> Void,
        redo: @escaping @MainActor () -> Void
    ) {
        (undoScope ?? defaultUndo).registerReversible(
            target: undoTarget, actionName: actionName, undo: undo, redo: redo)
    }

    /// Register an ALTERNATING pair whose two directions are not symmetric
    /// closures over one captured value: each direction produces the input the
    /// other needs (delete yields a snapshot, restore yields an id).
    ///
    /// The value produced by the most recent run is carried in a box, so a redo
    /// re-deletes and the NEXT undo restores the FRESH snapshot rather than a
    /// stale one. That is `ManuscriptStoreAdapter`'s mutually-recursive
    /// `registerCollection{Exists,Deleted}Undo` pair, generalised. It is also
    /// observationally identical to the stale-snapshot form
    /// `CollectionStoreAdapter` used: any mutation that could invalidate the
    /// snapshot registers an undo entry, which clears the redo stack, so a redo
    /// can only ever fire against an unchanged store.
    ///
    /// - Parameters:
    ///   - capturedValue: `nil` when the row currently EXISTS, so ⌘Z must run
    ///     `produce` first (delete it, capturing the snapshot); non-`nil` when
    ///     the row has just been deleted, so ⌘Z runs `consume` on that snapshot.
    ///   - produce: the direction that yields the value the other one needs
    ///     (`nil` = the verb failed; the alternation then simply does nothing).
    ///   - consume: the direction that takes the produced value.
    public func registerAlternating<Value>(
        _ undoScope: StoreUndoScope?,
        actionName: String,
        capturedValue: Value?,
        produce: @escaping @MainActor () -> Value?,
        consume: @escaping @MainActor (Value) -> Void
    ) {
        let box = Box<Value?>(capturedValue)
        let produceStep: @MainActor () -> Void = {
            if let next = produce() { box.value = next }
        }
        let consumeStep: @MainActor () -> Void = {
            if let current = box.value { consume(current) }
        }
        if capturedValue == nil {
            registerReversible(
                undoScope, actionName: actionName, undo: produceStep, redo: consumeStep)
        } else {
            registerReversible(
                undoScope, actionName: actionName, undo: consumeStep, redo: produceStep)
        }
    }

    /// Mutable capture cell for `registerAlternating`.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}
