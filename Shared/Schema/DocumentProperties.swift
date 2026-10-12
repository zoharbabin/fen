import Foundation

/// Turns the values of a document's front matter into text for a form, and back into one line of
/// YAML for `FrontMatterEditor` (issue #7). Values stay plain YAML in the file.
public enum DocumentProperties {
    private static let isoDate = "^\\d{4}-\\d{2}-\\d{2}$"

    /// The `type:` of a document, if it has one.
    public static func typeName(in frontMatter: [String: Any]?) -> String? {
        (frontMatter?["type"] as? String)?.trimmingCharacters(in: .whitespaces)
    }

    /// What a form field shows for a value read by Yams.
    public static func text(for value: Any?) -> String {
        switch value {
        case nil: ""
        case let string as String: string
        case let bool as Bool: bool ? "true" : "false"
        case let int as Int: String(int)
        case let double as Double: number(double)
        case let date as Date: dateFormatter.string(from: date)
        case let list as [Any]: list.map { text(for: $0) }.joined(separator: ", ")
        default: ""
        }
    }

    private static func number(_ value: Double) -> String {
        let isWhole = value.rounded() == value && abs(value) < 1e15
        return isWhole ? String(Int(value)) : String(value)
    }

    /// `true` when the form can edit this value on one line. A mapping, or a list of mappings, can't.
    public static func isEditable(_ value: Any?) -> Bool {
        switch value {
        case nil, is String, is Bool, is Int, is Double, is Date: true
        case let list as [Any]: list.allSatisfy { $0 is String || $0 is Int || $0 is Double || $0 is Bool }
        default: false
        }
    }

    /// One line of YAML for `input`, or `nil` when the field is cleared. Throws when `input`
    /// doesn't fit the field's kind, so the form can say so instead of writing a wrong value.
    public static func yaml(for field: SchemaField, input: String) throws -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        switch field.kind {
        case .text:
            return FrontMatterEditor.scalar(trimmed)
        case .choice:
            return FrontMatterEditor.scalar(trimmed)
        case .boolean:
            guard let value = ["true": "true", "yes": "true", "false": "false", "no": "false"][trimmed.lowercased()]
            else {
                throw PropertyError.notABoolean
            }
            return value
        case .number:
            guard let number = Double(trimmed), number.isFinite else { throw PropertyError.notANumber }
            return trimmed
        case .date:
            guard trimmed.range(of: isoDate, options: .regularExpression) != nil,
                  dateFormatter.date(from: trimmed) != nil else { throw PropertyError.notADate }
            return trimmed
        case .list:
            let parts = trimmed.split(separator: ",")
            let items = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return "[" + items.map(FrontMatterEditor.scalar).joined(separator: ", ") + "]"
        }
    }

    /// The day shown in a date picker for `text` (`2026-03-31`), at the start of that day in
    /// `calendar`. A date field holds a day, not a moment, so no time zone shifts it.
    public static func day(from text: String, calendar: Calendar = .current) -> Date? {
        guard text.range(of: isoDate, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return date
    }

    /// `2026-03-31` for the day `date` falls on in `calendar`.
    public static func text(forDay date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

public enum PropertyError: Error, Equatable, LocalizedError {
    case notABoolean
    case notANumber
    case notADate

    public var errorDescription: String? {
        switch self {
        case .notABoolean: "Use yes or no."
        case .notANumber: "Use a number."
        case .notADate: "Use a date like 2026-03-31."
        }
    }
}
