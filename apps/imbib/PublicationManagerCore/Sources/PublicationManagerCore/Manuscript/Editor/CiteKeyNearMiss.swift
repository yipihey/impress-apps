//
//  CiteKeyNearMiss.swift
//  PublicationManagerCore
//
//  A cite key the library does not have, and the library key it almost is.
//
//  `@AminJainKarurMocz202` is `AminJainKarurMocz2022` with the year cut off.
//  `@GosencPaEtAl2023` is `GosencaEtAl2023` with one character different.
//  `@AlonStreltsovCederbaum2008:` picked up the colon after the key. Each of
//  those used to come back as "no paper", which is true and useless: the
//  paper is in the library under the neighbouring key.
//

import Foundation
import ImbibRustCore

enum CiteKeyNearMiss {

    /// Drop a leading `@` and any trailing characters that are not part of a
    /// cite key. The compile-time scanner treats `:` as a key character, so
    /// `@AlonStreltsovCederbaum2008:` arrives with the colon still attached.
    static func normalize(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("@") { key.removeFirst() }
        while let last = key.last, !isKeyCharacter(last) {
            key.removeLast()
        }
        return key
    }

    /// A single token long enough to be a cite key rather than a title word.
    static func looksLikeCiteKey(_ raw: String) -> Bool {
        let key = normalize(raw)
        guard key.count >= 8, let first = key.first, first.isASCII && first.isLetter else {
            return false
        }
        return key.allSatisfy(isKeyCharacter)
    }

    /// The closest candidate, or nil when nothing is near enough — or when
    /// two candidates are equally near, so we do not guess.
    static func suggest(query raw: String, candidates: [String]) -> String? {
        let query = normalize(raw)
        guard looksLikeCiteKey(query) else { return nil }
        var best: (key: String, distance: Int)?
        var tied = false
        for rawCandidate in candidates {
            let candidate = normalize(rawCandidate)
            guard candidate != query else { continue }
            guard let distance = nearness(query, candidate) else { continue }
            if let current = best {
                if distance < current.distance {
                    best = (candidate, distance)
                    tied = false
                } else if distance == current.distance, candidate != current.key {
                    tied = true
                }
            } else {
                best = (candidate, distance)
            }
        }
        guard let best, !tied else { return nil }
        return best.key
    }

    /// The library row to offer, or nil when the key is already exact or
    /// nothing nearby is close enough to name.
    @MainActor
    static func suggestion(
        for raw: String,
        in search: ManuscriptCitationSearching
    ) -> BibliographyRow? {
        let key = normalize(raw)
        guard looksLikeCiteKey(key) else { return nil }
        if let exact = search.findByCiteKey(key) {
            // Trailing punctuation was the whole miss: the library has this key.
            let significant = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .drop { $0 == "@" }
            return String(significant) == key ? nil : exact
        }
        var rows: [BibliographyRow] = []
        var seen = Set<String>()
        func add(_ found: [BibliographyRow]) {
            for row in found where seen.insert(row.id).inserted {
                rows.append(row)
            }
        }
        add(search.search(key, limit: 20))
        // The full miss is often not a substring of the real key
        // (`GosencPa…` vs `Gosenca…`). The first six characters usually are.
        if key.count > 6 {
            add(search.search(String(key.prefix(6)), limit: 40))
        }
        guard let citeKey = suggest(query: key, candidates: rows.map(\.citeKey)) else {
            return nil
        }
        return rows.first { $0.citeKey == citeKey }
    }

    // MARK: - Distance

    /// Edit distance when the two keys are the same citation, otherwise nil.
    /// A shared prefix with a short tail (a cut-off year) counts, as does one
    /// or two edits in a key of real length.
    static func nearness(_ query: String, _ candidate: String) -> Int? {
        guard query != candidate else { return nil }
        let shorter = min(query.count, candidate.count)
        guard shorter >= 8 else { return nil }
        if query.hasPrefix(candidate) || candidate.hasPrefix(query) {
            let extra = abs(query.count - candidate.count)
            if extra >= 1, extra <= 4 { return extra }
        }
        let distance = levenshtein(query, candidate)
        if distance >= 1, distance <= 2 { return distance }
        return nil
    }

    private static func isKeyCharacter(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter || character.isNumber || character == "_" || character == "-")
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let left = Array(a)
        let right = Array(b)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        for (i, ca) in left.enumerated() {
            var current = [i + 1]
            for (j, cb) in right.enumerated() {
                let insert = current[j] + 1
                let delete = previous[j + 1] + 1
                let replace = previous[j] + (ca == cb ? 0 : 1)
                current.append(min(insert, delete, replace))
            }
            previous = current
        }
        return previous[right.count]
    }
}
