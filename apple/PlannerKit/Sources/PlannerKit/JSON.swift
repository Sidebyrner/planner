import Foundation

/// The server sends and accepts ISO 8601 dates in UTC, normally with milliseconds
/// ("2026-11-23T13:00:00.000Z"), which is what `Date.toISOString()` produces.
public enum PlannerJSON {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    public static func parseDate(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: withFraction) { return date }
        return try? Date(string, strategy: plain)
    }

    public static func format(_ date: Date) -> String {
        date.formatted(withFraction)
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(string)")
            }
            return date
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
