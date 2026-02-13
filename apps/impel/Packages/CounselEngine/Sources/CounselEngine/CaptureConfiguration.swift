//
//  CaptureConfiguration.swift
//  CounselEngine
//
//  Configuration for the email-to-artifact capture pipeline.
//

import Foundation

/// Configuration for the capture@ email-to-artifact pipeline.
public struct CaptureConfiguration: Sendable {
    /// Tags to apply to every captured artifact (e.g., ["email-capture"]).
    public let defaultTags: [String]

    /// Maximum attachment size in bytes (default: 25 MB).
    public let maxAttachmentSize: Int64

    /// Prefer plain text body over HTML when both are available.
    public let preferPlainText: Bool

    /// Path for the watched .eml folder (nil to disable).
    public let watchedFolderPath: String?

    public init(
        defaultTags: [String] = ["email-capture"],
        maxAttachmentSize: Int64 = 25 * 1024 * 1024,
        preferPlainText: Bool = true,
        watchedFolderPath: String? = nil
    ) {
        self.defaultTags = defaultTags
        self.maxAttachmentSize = maxAttachmentSize
        self.preferPlainText = preferPlainText
        self.watchedFolderPath = watchedFolderPath
    }

    /// Default configuration.
    public static let `default` = CaptureConfiguration()
}
