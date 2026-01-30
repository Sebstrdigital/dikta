import Foundation

/// A single dictation history item
struct HistoryItem: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var timestamp: Date
    var outputMode: OutputMode

    init(text: String, outputMode: OutputMode) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.outputMode = outputMode
    }

    /// Preview text for menu display (truncated)
    var preview: String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > 40 {
            return String(cleaned.prefix(40)) + "..."
        }
        return cleaned
    }

    // Custom coding keys to match Python format
    enum CodingKeys: String, CodingKey {
        case text
        case timestamp
        case outputMode = "output_mode"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.text = try container.decode(String.self, forKey: .text)

        // Handle ISO8601 date string from Python
        let timestampString = try container.decode(String.self, forKey: .timestamp)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestampString) {
            self.timestamp = date
        } else {
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            self.timestamp = formatter.date(from: timestampString) ?? Date()
        }

        // Handle string output mode
        let modeString = try container.decode(String.self, forKey: .outputMode)
        self.outputMode = OutputMode(rawValue: modeString) ?? .general
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        try container.encode(formatter.string(from: timestamp), forKey: .timestamp)

        try container.encode(outputMode.rawValue, forKey: .outputMode)
    }
}
