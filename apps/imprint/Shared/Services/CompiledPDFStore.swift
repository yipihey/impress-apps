//
//  CompiledPDFStore.swift
//  imprint
//
//  Publishes each document's latest compiled PDF so scenes other than the
//  editor window (the detached PDF preview on a second display, and any future
//  agent surface) can observe it declaratively. The editor's ContentView is
//  the single writer: it forwards `vm.pdfData` after every compile.
//

import Foundation
import Observation

@MainActor
@Observable
final class CompiledPDFStore {
    static let shared = CompiledPDFStore()
    private init() {}

    struct Entry {
        var title: String
        var pdfData: Data?
        var isCompiling: Bool
    }

    private(set) var entries: [UUID: Entry] = [:]

    func publish(documentID: UUID, title: String, pdfData: Data?, isCompiling: Bool) {
        entries[documentID] = Entry(title: title, pdfData: pdfData, isCompiling: isCompiling)
    }

    func entry(for documentID: UUID) -> Entry? {
        entries[documentID]
    }
}

extension Notification.Name {
    /// Posted by the View menu / shortcuts to open the compiled PDF of the
    /// frontmost document in a detached window (second display when present).
    static let openDetachedPDF = Notification.Name("com.imprint.openDetachedPDF")
}
