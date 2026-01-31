//
//  SearchService.swift
//  MessageManagerCore
//
//  Full-text search over messages using Core Data.
//

import Foundation
import CoreData
import OSLog

private let searchLogger = Logger(subsystem: "com.impress.impart", category: "search")

// MARK: - Search Service

/// Service for searching messages.
public actor SearchService {
    private let persistence: PersistenceController

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    /// Search messages by query.
    public func search(query: String, accountId: UUID? = nil, folderId: UUID? = nil) async throws -> [Message] {
        guard !query.isEmpty else { return [] }

        return try await persistence.performBackgroundTask { context in
            let request = CDMessage.fetchRequest()

            var predicates: [NSPredicate] = []

            // Text search predicate
            let searchPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "subject CONTAINS[cd] %@", query),
                NSPredicate(format: "snippet CONTAINS[cd] %@", query),
                NSPredicate(format: "fromJSON CONTAINS[cd] %@", query),
                NSPredicate(format: "toJSON CONTAINS[cd] %@", query)
            ])
            predicates.append(searchPredicate)

            // Optional account filter
            if let accountId {
                predicates.append(NSPredicate(format: "folder.account.id == %@", accountId as CVarArg))
            }

            // Optional folder filter
            if let folderId {
                predicates.append(NSPredicate(format: "folder.id == %@", folderId as CVarArg))
            }

            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.date, ascending: false)]
            request.fetchLimit = 100

            let cdMessages = try context.fetch(request)
            searchLogger.info("Search '\(query)' returned \(cdMessages.count) results")

            return cdMessages.map { $0.toMessage() }
        }
    }

    /// Search with advanced filters.
    public func advancedSearch(_ criteria: SearchCriteria) async throws -> [Message] {
        return try await persistence.performBackgroundTask { context in
            let request = CDMessage.fetchRequest()

            var predicates: [NSPredicate] = []

            if let query = criteria.query, !query.isEmpty {
                predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "subject CONTAINS[cd] %@", query),
                    NSPredicate(format: "snippet CONTAINS[cd] %@", query)
                ]))
            }

            if let from = criteria.from {
                predicates.append(NSPredicate(format: "fromJSON CONTAINS[cd] %@", from))
            }

            if let to = criteria.to {
                predicates.append(NSPredicate(format: "toJSON CONTAINS[cd] %@", to))
            }

            if let after = criteria.after {
                predicates.append(NSPredicate(format: "date >= %@", after as NSDate))
            }

            if let before = criteria.before {
                predicates.append(NSPredicate(format: "date <= %@", before as NSDate))
            }

            if criteria.hasAttachments == true {
                predicates.append(NSPredicate(format: "hasAttachments == YES"))
            }

            if criteria.isUnread == true {
                predicates.append(NSPredicate(format: "isRead == NO"))
            }

            if criteria.isStarred == true {
                predicates.append(NSPredicate(format: "isStarred == YES"))
            }

            if let accountId = criteria.accountId {
                predicates.append(NSPredicate(format: "folder.account.id == %@", accountId as CVarArg))
            }

            if let folderId = criteria.folderId {
                predicates.append(NSPredicate(format: "folder.id == %@", folderId as CVarArg))
            }

            request.predicate = predicates.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.date, ascending: false)]
            request.fetchLimit = criteria.limit ?? 100

            let cdMessages = try context.fetch(request)
            searchLogger.info("Advanced search returned \(cdMessages.count) results")

            return cdMessages.map { $0.toMessage() }
        }
    }

    /// Search for messages by subject pattern.
    public func searchBySubject(_ pattern: String) async throws -> [Message] {
        return try await search(query: pattern)
    }

    /// Search for messages from a specific sender.
    public func searchBySender(_ senderEmail: String) async throws -> [Message] {
        return try await advancedSearch(SearchCriteria(from: senderEmail))
    }

    /// Search for unread messages.
    public func searchUnread(accountId: UUID? = nil) async throws -> [Message] {
        return try await advancedSearch(SearchCriteria(
            isUnread: true,
            accountId: accountId
        ))
    }

    /// Search for starred messages.
    public func searchStarred(accountId: UUID? = nil) async throws -> [Message] {
        return try await advancedSearch(SearchCriteria(
            isStarred: true,
            accountId: accountId
        ))
    }

    /// Search for messages with attachments.
    public func searchWithAttachments(accountId: UUID? = nil) async throws -> [Message] {
        return try await advancedSearch(SearchCriteria(
            hasAttachments: true,
            accountId: accountId
        ))
    }

    /// Search messages in a date range.
    public func searchInDateRange(from startDate: Date, to endDate: Date, accountId: UUID? = nil) async throws -> [Message] {
        return try await advancedSearch(SearchCriteria(
            after: startDate,
            before: endDate,
            accountId: accountId
        ))
    }
}

// MARK: - Search Criteria

/// Criteria for advanced message search.
public struct SearchCriteria: Sendable {
    public var query: String?
    public var from: String?
    public var to: String?
    public var after: Date?
    public var before: Date?
    public var hasAttachments: Bool?
    public var isUnread: Bool?
    public var isStarred: Bool?
    public var accountId: UUID?
    public var folderId: UUID?
    public var limit: Int?

    public init(
        query: String? = nil,
        from: String? = nil,
        to: String? = nil,
        after: Date? = nil,
        before: Date? = nil,
        hasAttachments: Bool? = nil,
        isUnread: Bool? = nil,
        isStarred: Bool? = nil,
        accountId: UUID? = nil,
        folderId: UUID? = nil,
        limit: Int? = nil
    ) {
        self.query = query
        self.from = from
        self.to = to
        self.after = after
        self.before = before
        self.hasAttachments = hasAttachments
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.accountId = accountId
        self.folderId = folderId
        self.limit = limit
    }
}

// MARK: - Search Result

/// A search result with relevance metadata.
public struct SearchResult: Sendable, Identifiable {
    public let id: UUID
    public let message: Message
    public let matchType: SearchMatchType
    public let matchedText: String?

    public init(message: Message, matchType: SearchMatchType, matchedText: String? = nil) {
        self.id = message.id
        self.message = message
        self.matchType = matchType
        self.matchedText = matchedText
    }
}

/// Type of search match.
public enum SearchMatchType: String, Sendable, CaseIterable {
    case subject
    case body
    case sender
    case recipient
    case attachment
}
