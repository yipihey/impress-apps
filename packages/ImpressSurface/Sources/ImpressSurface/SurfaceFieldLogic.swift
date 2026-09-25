//
//  SurfaceFieldLogic.swift
//  ImpressSurface
//
//  The few decisions `SurfaceView`'s fields make about WHEN a value leaves
//  the view, kept out of the views so a test can pin them (plan wave 7, T3).
//  None of this is surface behaviour — what a change DOES is Rust's `reduce`
//  — it is only "did the person actually give us a value yet".
//
//  - A typed draft is sent when the field loses focus, on Return, and before
//    any other widget's click, select or submit goes out, so a button always
//    acts on what is on screen (SK-K3). It used to be sent on Return only:
//    type, click the button, and the button ran on the old state and the
//    re-render erased the typing.
//  - A select or date field never sends a value the person did not choose
//    (SK-K12). Seeding a draft used to fire the field's own change handler,
//    so a select bound to null sent its first option, and a date field wrote
//    today's timestamp into state on first render whenever the stored value
//    was not a full ISO-8601 date-time.
//

import Foundation

// MARK: - Drafts

/// Values typed into `text` / `number` fields and not yet sent, oldest
/// first. One per `SurfaceView`, shared by its fields.
@MainActor
public final class SurfaceDraftBook {

    private var pending: [(id: String, value: SurfaceJSONValue)] = []

    public init() {}

    /// Record what field `id` shows now, or with nil, that it shows the
    /// stored value again (nothing to send).
    public func stage(_ id: String, _ value: SurfaceJSONValue?) {
        pending.removeAll { $0.id == id }
        if let value { pending.append((id, value)) }
    }

    public func has(_ id: String) -> Bool {
        pending.contains { $0.id == id }
    }

    /// Field `id`'s unsent value, removed from the book.
    public func take(_ id: String) -> SurfaceJSONValue? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        return pending.remove(at: index).value
    }

    /// Every unsent value, oldest first, removed from the book.
    public func takeAll() -> [(id: String, value: SurfaceJSONValue)] {
        defer { pending.removeAll() }
        return pending
    }

    /// The events that leave the view for `event`: a `change` goes alone (it
    /// IS the value, so any draft of that field is spent); anything else —
    /// a click, a select, a submit — goes after a `change` for every field
    /// whose draft was not yet sent, so the action sees the typed values.
    public func outgoing(_ event: SurfaceEvent) -> [SurfaceEvent] {
        if event.kind == .change {
            stage(event.widget, nil)
            return [event]
        }
        let flushed = takeAll().map {
            SurfaceEvent(widget: $0.id, kind: .change, value: $0.value)
        }
        return flushed + [event]
    }
}

// MARK: - Seeds and emits

/// Pure helpers the field views call.
public enum SurfaceFieldLogic {

    /// A text field's draft for a stored value.
    public static func textSeed(_ value: SurfaceJSONValue) -> String {
        value.stringValue ?? ""
    }

    /// What a text field's current text means: nil when it is the stored
    /// value (nothing to send), else the value to send.
    public static func textDraft(_ text: String, stored: SurfaceJSONValue) -> SurfaceJSONValue? {
        text == textSeed(stored) ? nil : .string(text)
    }

    public static func numberSeed(_ value: SurfaceJSONValue) -> String {
        guard let number = value.doubleValue else { return "" }
        if number == number.rounded(), abs(number) < 1e15 { return String(Int(number)) }
        return String(number)
    }

    /// A number field's text, as a value to send: nil when it is not a
    /// number (nothing sendable) or equals the stored value.
    public static func numberDraft(_ text: String, stored: SurfaceJSONValue) -> SurfaceJSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let parsed = Double(trimmed) else { return nil }
        if let current = stored.doubleValue, current == parsed { return nil }
        return .double(parsed)
    }

    /// A select's draft: the stored option, or "" — NOT the first option —
    /// when nothing is stored, so showing the field chooses nothing.
    public static func selectSeed(_ value: SurfaceJSONValue) -> String {
        value.stringValue ?? ""
    }

    /// Send a select's draft only when the person chose something other
    /// than what is stored.
    public static func selectShouldEmit(_ draft: String, stored: SurfaceJSONValue) -> Bool {
        draft != selectSeed(stored)
    }

    // MARK: Dates

    /// A date field's value is a calendar DATE. An agent's natural
    /// `"2026-09-25"` and a full ISO-8601 date-time are both accepted; a
    /// date-only value is read in the person's own calendar, so it shows
    /// as the day it names rather than the day before west of UTC.
    public static func parseDate(_ value: SurfaceJSONValue, calendar: Calendar = .current) -> Date? {
        guard let string = value.stringValue?.trimmingCharacters(in: .whitespaces),
              !string.isEmpty
        else { return nil }
        if isDateOnly(string) {
            return dateOnlyFormatter(calendar).date(from: string)
        }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: string) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return full.date(from: string)
    }

    /// The string to send for `date`, in the SAME shape as the stored value:
    /// `yyyy-MM-dd` when the stored value is date-only, an ISO-8601
    /// date-time otherwise (what this field has always sent). A field never
    /// rewrites an agent's format.
    public static func dateString(
        _ date: Date, like stored: SurfaceJSONValue, calendar: Calendar = .current
    ) -> String {
        if let string = stored.stringValue, isDateOnly(string) {
            return dateOnlyFormatter(calendar).string(from: date)
        }
        return ISO8601DateFormatter().string(from: date)
    }

    /// Send a date draft only when it is a different DAY from the stored
    /// value — the picker shows days, so a same-day difference is not a
    /// choice the person made.
    public static func dateShouldEmit(
        _ draft: Date, stored: SurfaceJSONValue, calendar: Calendar = .current
    ) -> Bool {
        guard let current = parseDate(stored, calendar: calendar) else { return true }
        return !calendar.isDate(current, inSameDayAs: draft)
    }

    static func isDateOnly(_ string: String) -> Bool {
        string.count == 10 && string.allSatisfy { $0.isNumber || $0 == "-" }
    }

    private static func dateOnlyFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

// MARK: - Keys a host routes in

/// The widget grammar's keys, sent INTO a `SurfaceView` by a host that owns
/// the window's one focus target (SK-K14): `.focusable()` must not wrap a
/// view that contains text fields, so the surface does not listen for keys
/// itself until one of its widgets has focus — the host's root does, and
/// forwards j / k / ⏎ / ⎋ here.
@MainActor
public final class SurfaceKeyInput {

    public enum Key: Sendable, Hashable {
        case next, previous, activate, leave
    }

    var handler: ((Key) -> Bool)?

    public init() {}

    /// Returns false when the surface did not use the key.
    @discardableResult
    public func send(_ key: Key) -> Bool {
        handler?(key) ?? false
    }
}
