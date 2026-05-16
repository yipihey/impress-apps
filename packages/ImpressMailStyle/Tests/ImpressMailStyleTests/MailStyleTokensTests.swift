//
//  MailStyleTokensTests.swift
//  ImpressMailStyleTests
//

import Foundation
import Testing
@testable import ImpressMailStyle

@Suite("MailStyleTokens")
struct MailStyleTokensTests {

    @Test("formatRelativeDate returns time for today")
    func todayFormatsAsTime() {
        let now = Date()
        let result = MailStyleTokens.formatRelativeDate(now)
        // Should contain AM or PM (time format)
        #expect(result.contains("AM") || result.contains("PM") || result.contains(":"))
    }

    @Test("formatRelativeDate returns Yesterday")
    func yesterdayFormatsCorrectly() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let result = MailStyleTokens.formatRelativeDate(yesterday)
        #expect(result == "Yesterday")
    }

    @Test("Default colors are not nil")
    func defaultColorsExist() {
        let colors = DefaultMailStyleColors()
        // Just verify the struct can be created and accessed
        _ = colors.primaryText
        _ = colors.secondaryText
        _ = colors.tertiaryText
        _ = colors.accent
        _ = colors.unreadDot
    }

    @Test("MailStyleRowConfiguration default values")
    func defaultConfiguration() {
        let config = MailStyleRowConfiguration.default
        #expect(config.showDate == true)
        #expect(config.showTitle == true)
        #expect(config.showSubtitle == false)
        #expect(config.showTrailingBadge == true)
        #expect(config.showUnreadIndicator == true)
        #expect(config.showAttachmentIndicator == true)
        #expect(config.showFlagStripe == true)
        #expect(config.previewLineLimit == 2)
        #expect(config.titleLineLimit == nil)
        #expect(config.density == .default)
    }

    @Test("MailStyleRowDensity raw values match imbib's RowDensity")
    func densityRawValues() {
        #expect(MailStyleRowDensity.compact.rawValue == "compact")
        #expect(MailStyleRowDensity.default.rawValue == "default")
        #expect(MailStyleRowDensity.spacious.rawValue == "spacious")
    }

    @Test("MailStyleRowDensity padding values")
    func densityPadding() {
        #expect(MailStyleRowDensity.compact.rowPadding == 4)
        #expect(MailStyleRowDensity.default.rowPadding == 8)
        #expect(MailStyleRowDensity.spacious.rowPadding == 12)
    }
}
