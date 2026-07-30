// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): the iOS list host's
// DATA half. The renderer (`RecordListHostView.swift`) is iOS-gated, the same
// data/view split `RecordSidebarModel` / `RecordSidebarView` uses.
//
//  RecordListHostModel.swift
//  ImpressChassis (lifted out of PublicationManagerCore by C5;
//  the renderer stayed behind, so the data/view split is a package boundary now)
//
//  C1 (2026-07-30) — what a single-kind iOS record list decides, as data.
//
//  Two rules, both of which were written twice (imprint-iOS's list inside
//  `IOSManuscriptLibraryView`, impart-iOS's `IOSMessageListColumn`) and neither
//  of which is a rendering question:
//
//    * WHICH OF THE THREE STATES the column is in. "Spinner, empty state, or
//      rows" is not "isLoading ? spinner : list": a reload that already has rows
//      on screen must keep showing them, or every store event flashes the list
//      to a spinner. impart got that right (`isLoading && rows.isEmpty`) and
//      imprint had no loading state at all, so the rule existed once and a half.
//    * THE ROW IDENTIFIER CONVENTION. `manuscriptRow.<uuid>` /
//      `messageRow.<uuid>` were spelled at each call site, and both UI suites
//      match them BY PREFIX — `LibraryShellUITests.firstRowTitle` and
//      `MailShellUITests`'s `BEGINSWITH` predicates. A prefix that only exists
//      as a literal in two view files and two test files is one rename away
//      from a suite that silently matches nothing.
//
//  Deliberately NOT here: which rows a query matches. imprint asks the STORE
//  (`searchManuscripts` + the scope intersection the adapter owns); impart
//  filters the loaded page over subject/from/preview, the same three fields
//  macOS's filter bar matches. Those are two different capabilities that happen
//  to share a text field, and unifying them would mean either an unbounded
//  client-side filter for manuscripts or an FTS index impart has no rows in.
//

import Foundation

/// Which of the three things a record list column shows.
public enum RecordListPhase: String, Equatable, Sendable, CaseIterable {
    /// A first read is in flight and there is nothing to show yet.
    case loading
    /// The read finished (or was never started) and produced no rows.
    case empty
    /// Rows — including while a RE-read is in flight.
    case rows

    /// The rule, in one place.
    ///
    /// `isLoading` only wins when the list is empty: a reload triggered by a
    /// store event, a scope revisit or pull-to-refresh happens with rows on
    /// screen, and replacing them with a spinner is a flash the user reads as
    /// data loss.
    public static func resolve(rowCount: Int, isLoading: Bool) -> RecordListPhase {
        if rowCount > 0 { return .rows }
        return isLoading ? .loading : .empty
    }
}

/// The accessibility-identifier convention for record rows.
///
/// One function so the prefix is declared once per kind by its host and the
/// suites can be written against `RecordListRowIdentity.prefix(...)`-shaped
/// strings rather than hand-spelled twins.
public enum RecordListRowIdentity {

    /// `<prefix><uuid>` — e.g. `manuscriptRow.4E2F…`.
    ///
    /// The prefix carries its own separator (`"manuscriptRow."`) because that
    /// is what both shipped suites already match on; changing the separator
    /// here would break them silently, which is exactly the failure this
    /// function exists to make impossible to reintroduce.
    public static func identifier(prefix: String, id: UUID) -> String {
        "\(prefix)\(id.uuidString)"
    }
}
