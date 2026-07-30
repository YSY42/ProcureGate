//
//  DateFormatting.swift
//  ProcureGate
//
//  Created by Naomi Yang on 27/07/2026.
//

import Foundation

private func parseISO8601(_ string: String) -> Date? {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: string) {
        return date
    }
    return ISO8601DateFormatter().date(from: string)
}

private let utcTimeZone = TimeZone(identifier: "UTC")!

private var utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcTimeZone
    return calendar
}()

private func utcDateTimeFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.timeZone = utcTimeZone
    return formatter
}

private func utcDateOnlyFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .none
    formatter.timeZone = utcTimeZone
    return formatter
}

extension String {
    /// Parses an ISO 8601 timestamp string (with or without fractional
    /// seconds) coming from the backend, and formats it into a human-
    /// readable date/time. Falls back to the raw string if parsing fails,
    /// so a malformed timestamp never crashes the UI — it just looks like
    /// the original value instead of a nicely formatted one.
    ///
    /// Always rendered in UTC (not the viewer's device time zone) and
    /// explicitly labeled as such — an audit trail is evidence that gets
    /// compared across time zones, so every viewer must see the same
    /// unambiguous timestamp rather than a silently-local one.
    var asFormattedDateTime: String {
        guard let date = parseISO8601(self) else { return self }
        return "\(utcDateTimeFormatter().string(from: date)) UTC"
    }

    /// Groups a timestamp by calendar day (in UTC, matching asFormattedDateTime)
    /// for feed-style section headers — "Today"/"Yesterday" for the two most
    /// recent days, otherwise a plain date. Falls back to the raw string if
    /// parsing fails.
    var asDayGroupLabel: String {
        guard let date = parseISO8601(self) else { return self }
        if utcCalendar.isDateInToday(date) { return "Today" }
        if utcCalendar.isDateInYesterday(date) { return "Yesterday" }
        return utcDateOnlyFormatter().string(from: date)
    }

    /// The parsed Date, for callers that need to filter/compare rather than
    /// display (e.g. a "last N days" range filter). Falls back to nil on a
    /// malformed timestamp — never crashes the UI.
    var asDate: Date? {
        parseISO8601(self)
    }
}
