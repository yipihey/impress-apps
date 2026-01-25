//
//  SmartCollectionEditor.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI

// MARK: - Smart Collection Editor

/// Editor for creating and editing smart collections.
public struct SmartCollectionEditor: View {

    // MARK: - Properties

    @Binding var isPresented: Bool
    let collection: CDCollection?
    let onSave: (String, String) -> Void  // (name, predicate)

    @State private var name: String = ""
    @State private var rules: [SmartCollectionRule] = []
    @State private var matchType: MatchType = .all

    // MARK: - Initialization

    public init(
        isPresented: Binding<Bool>,
        collection: CDCollection? = nil,
        onSave: @escaping (String, String) -> Void
    ) {
        self._isPresented = isPresented
        self.collection = collection
        self.onSave = onSave
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            Form {
                // Name
                Section("Name") {
                    TextField("Collection Name", text: $name)
                }

                // Match type
                Section("Match") {
                    Picker("Match", selection: $matchType) {
                        Text("All of the following").tag(MatchType.all)
                        Text("Any of the following").tag(MatchType.any)
                    }
                    .pickerStyle(.segmented)
                }

                // Rules
                Section("Rules") {
                    ForEach($rules) { $rule in
                        RuleRow(rule: $rule)
                    }
                    .onDelete(perform: deleteRule)

                    Button {
                        addRule()
                    } label: {
                        Label("Add Rule", systemImage: "plus.circle")
                    }
                }

                // Preview
                if !rules.isEmpty {
                    Section("Predicate Preview") {
                        Text(buildPredicate())
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(collection == nil ? "New Smart Collection" : "Edit Smart Collection")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(name.isEmpty || rules.isEmpty)
                }
            }
            .onAppear {
                loadFromCollection()
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
    }

    // MARK: - Actions

    private func addRule() {
        rules.append(SmartCollectionRule())
    }

    private func deleteRule(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
    }

    private func loadFromCollection() {
        guard let collection else {
            // New collection - start with one empty rule
            rules = [SmartCollectionRule()]
            return
        }

        name = collection.name

        // Parse existing predicate
        if let predicate = collection.predicate {
            let parsed = SmartCollectionRule.parse(predicate: predicate)
            matchType = parsed.matchType
            rules = parsed.rules.isEmpty ? [SmartCollectionRule()] : parsed.rules
        } else {
            rules = [SmartCollectionRule()]
        }
    }

    private func buildPredicate() -> String {
        let validRules = rules.filter { $0.isValid }
        guard !validRules.isEmpty else { return "" }

        let predicates = validRules.map { $0.toPredicate() }

        switch matchType {
        case .all:
            return predicates.joined(separator: " AND ")
        case .any:
            return predicates.joined(separator: " OR ")
        }
    }

    private func save() {
        let predicate = buildPredicate()
        onSave(name, predicate)
        isPresented = false
    }
}

// MARK: - Match Type

public enum MatchType: String, CaseIterable {
    case all
    case any
}

// MARK: - Smart Collection Rule

public struct SmartCollectionRule: Identifiable {
    public let id = UUID()
    public var field: RuleField = .title
    public var comparison: RuleComparison = .contains
    public var value: String = ""

    public init(field: RuleField = .title, comparison: RuleComparison = .contains, value: String = "") {
        self.field = field
        self.comparison = comparison
        self.value = value
    }

    public var isValid: Bool {
        // Boolean comparisons don't need a value
        if comparison == .isTrue || comparison == .isFalse {
            return true
        }
        return !value.isEmpty
    }

    public func toPredicate() -> String {
        let fieldKey = field.predicateKey
        let escapedValue = value.replacingOccurrences(of: "'", with: "\\'")

        // Fields stored in rawFields JSON need special handling
        // We search the JSON string directly since Core Data can't query JSON fields
        if field.isStoredInRawFields {
            switch comparison {
            case .contains:
                // Search for the key and value pattern in JSON: "author": "...value..."
                return "rawFields CONTAINS[cd] '\(escapedValue)'"
            case .doesNotContain:
                return "NOT (rawFields CONTAINS[cd] '\(escapedValue)')"
            case .equals, .beginsWith, .endsWith:
                // For exact/prefix/suffix match on JSON fields, we can only do contains
                return "rawFields CONTAINS[cd] '\(escapedValue)'"
            default:
                return "rawFields CONTAINS[cd] '\(escapedValue)'"
            }
        }

        // Direct Core Data attributes
        switch comparison {
        case .contains:
            return "\(fieldKey) CONTAINS[cd] '\(escapedValue)'"
        case .doesNotContain:
            return "NOT (\(fieldKey) CONTAINS[cd] '\(escapedValue)')"
        case .equals:
            return "\(fieldKey) ==[cd] '\(escapedValue)'"
        case .notEquals:
            return "\(fieldKey) !=[cd] '\(escapedValue)'"
        case .beginsWith:
            return "\(fieldKey) BEGINSWITH[cd] '\(escapedValue)'"
        case .endsWith:
            return "\(fieldKey) ENDSWITH[cd] '\(escapedValue)'"
        case .greaterThan:
            return "\(fieldKey) > \(escapedValue)"
        case .lessThan:
            return "\(fieldKey) < \(escapedValue)"
        case .isTrue:
            return "\(fieldKey) == YES"
        case .isFalse:
            return "\(fieldKey) == NO"
        }
    }

    /// Parse a predicate string into rules
    public static func parse(predicate: String) -> (matchType: MatchType, rules: [SmartCollectionRule]) {
        // Determine match type
        let matchType: MatchType = predicate.contains(" AND ") ? .all : .any

        // Split by AND/OR
        let separator = matchType == .all ? " AND " : " OR "
        let parts = predicate.components(separatedBy: separator)

        var rules: [SmartCollectionRule] = []

        for part in parts {
            if let rule = parseRule(part.trimmingCharacters(in: .whitespaces)) {
                rules.append(rule)
            }
        }

        return (matchType, rules)
    }

    private static func parseRule(_ part: String) -> SmartCollectionRule? {
        // Try to parse common patterns
        // Pattern: field CONTAINS[cd] 'value'
        if let match = part.range(of: #"(\w+)\s+CONTAINS\[cd\]\s+'([^']+)'"#, options: .regularExpression) {
            let matched = String(part[match])
            let components = matched.components(separatedBy: " CONTAINS[cd] ")
            if components.count == 2 {
                let fieldName = components[0]
                let value = components[1].trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                if let field = RuleField.from(predicateKey: fieldName) {
                    return SmartCollectionRule(field: field, comparison: .contains, value: value)
                }
            }
        }

        // Pattern: field > value (for year)
        if let match = part.range(of: #"(\w+)\s+>\s+(\d+)"#, options: .regularExpression) {
            let matched = String(part[match])
            let components = matched.components(separatedBy: " > ")
            if components.count == 2 {
                let fieldName = components[0]
                let value = components[1]
                if let field = RuleField.from(predicateKey: fieldName) {
                    return SmartCollectionRule(field: field, comparison: .greaterThan, value: value)
                }
            }
        }

        // Pattern: field < value (for year)
        if let match = part.range(of: #"(\w+)\s+<\s+(\d+)"#, options: .regularExpression) {
            let matched = String(part[match])
            let components = matched.components(separatedBy: " < ")
            if components.count == 2 {
                let fieldName = components[0]
                let value = components[1]
                if let field = RuleField.from(predicateKey: fieldName) {
                    return SmartCollectionRule(field: field, comparison: .lessThan, value: value)
                }
            }
        }

        return nil
    }
}

// MARK: - Rule Field

public enum RuleField: String, CaseIterable, Identifiable {
    case title
    case author       // Stored in rawFields JSON
    case year
    case journal      // Stored in rawFields JSON
    case citeKey
    case entryType
    case abstract
    case keywords     // Stored in rawFields JSON
    case doi
    case isRead
    case isStarred

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .author: return "Author"
        case .year: return "Year"
        case .journal: return "Journal"
        case .citeKey: return "Cite Key"
        case .entryType: return "Entry Type"
        case .abstract: return "Abstract"
        case .keywords: return "Keywords"
        case .doi: return "DOI"
        case .isRead: return "Read Status"
        case .isStarred: return "Starred"
        }
    }

    /// Whether this field is stored in rawFields JSON (vs direct Core Data attribute)
    public var isStoredInRawFields: Bool {
        switch self {
        case .author, .journal, .keywords:
            return true
        default:
            return false
        }
    }

    /// The Core Data attribute key or rawFields key
    public var predicateKey: String {
        switch self {
        case .title: return "title"
        case .author: return "author"      // Key in rawFields JSON
        case .year: return "year"
        case .journal: return "journal"    // Key in rawFields JSON
        case .citeKey: return "citeKey"
        case .entryType: return "entryType"
        case .abstract: return "abstract"
        case .keywords: return "keywords"  // Key in rawFields JSON
        case .doi: return "doi"
        case .isRead: return "isRead"
        case .isStarred: return "isStarred"
        }
    }

    public var availableComparisons: [RuleComparison] {
        switch self {
        case .year:
            return [.equals, .greaterThan, .lessThan]
        case .isRead, .isStarred:
            return [.isTrue, .isFalse]
        case .title, .author, .journal, .abstract, .keywords:
            return [.contains, .doesNotContain, .equals, .beginsWith, .endsWith]
        case .citeKey, .entryType, .doi:
            return [.contains, .equals, .beginsWith]
        }
    }

    public static func from(predicateKey: String) -> RuleField? {
        RuleField.allCases.first { $0.predicateKey == predicateKey }
    }
}

// MARK: - Rule Comparison

public enum RuleComparison: String, CaseIterable, Identifiable {
    case contains
    case doesNotContain
    case equals
    case notEquals
    case beginsWith
    case endsWith
    case greaterThan
    case lessThan
    case isTrue
    case isFalse

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .contains: return "contains"
        case .doesNotContain: return "does not contain"
        case .equals: return "is"
        case .notEquals: return "is not"
        case .beginsWith: return "begins with"
        case .endsWith: return "ends with"
        case .greaterThan: return "is greater than"
        case .lessThan: return "is less than"
        case .isTrue: return "is true"
        case .isFalse: return "is false"
        }
    }
}

// MARK: - Rule Row View

struct RuleRow: View {
    @Binding var rule: SmartCollectionRule

    var body: some View {
        HStack(spacing: 12) {
            // Field picker
            Picker("Field", selection: $rule.field) {
                ForEach(RuleField.allCases) { field in
                    Text(field.displayName).tag(field)
                }
            }
            .labelsHidden()
            #if os(macOS)
            .pickerStyle(.menu)
            .frame(width: 120)
            #endif

            // Comparison picker
            Picker("Comparison", selection: $rule.comparison) {
                ForEach(rule.field.availableComparisons) { comparison in
                    Text(comparison.displayName).tag(comparison)
                }
            }
            .labelsHidden()
            #if os(macOS)
            .pickerStyle(.menu)
            .frame(width: 160)
            #endif
            .onChange(of: rule.field) { _, newField in
                // Reset comparison if not available for new field
                if !newField.availableComparisons.contains(rule.comparison) {
                    rule.comparison = newField.availableComparisons.first ?? .contains
                }
            }

            // Value field
            if rule.comparison != .isTrue && rule.comparison != .isFalse {
                TextField("Value", text: $rule.value)
                    .frame(minWidth: 150)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
            }
        }
    }
}

// MARK: - Preview

#Preview("New Smart Collection") {
    struct PreviewContainer: View {
        @State private var isPresented = true

        var body: some View {
            SmartCollectionEditor(isPresented: $isPresented) { name, predicate in
                print("Created: \(name) - \(predicate)")
            }
        }
    }

    return PreviewContainer()
}
