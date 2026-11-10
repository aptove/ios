import Foundation

/// A scheduled task stored on the bridge in `.aptove/tasks/`.
struct ScheduledTask: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var prompt: String
    var schedule: TaskSchedule
    var enabled: Bool
    let createdAt: String
    var lastRunAt: String?
    var nextRunAt: String?
}

/// How a task is scheduled — once at a specific time, or recurring.
enum TaskSchedule: Codable, Equatable {
    case once(at: String)
    case recurring(frequency: TaskFrequency, time: String, dayOfWeek: Int?, dayOfMonth: Int?, timezone: String)

    // MARK: - Codable (matches Rust serde tagged enum)

    private enum CodingKeys: String, CodingKey {
        case type, at, frequency, time, dayOfWeek, dayOfMonth, timezone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "once":
            let at = try container.decode(String.self, forKey: .at)
            self = .once(at: at)
        case "recurring":
            let frequency = try container.decode(TaskFrequency.self, forKey: .frequency)
            let time = try container.decode(String.self, forKey: .time)
            let dayOfWeek = try container.decodeIfPresent(Int.self, forKey: .dayOfWeek)
            let dayOfMonth = try container.decodeIfPresent(Int.self, forKey: .dayOfMonth)
            let timezone = try container.decode(String.self, forKey: .timezone)
            self = .recurring(frequency: frequency, time: time, dayOfWeek: dayOfWeek, dayOfMonth: dayOfMonth, timezone: timezone)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown schedule type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .once(let at):
            try container.encode("once", forKey: .type)
            try container.encode(at, forKey: .at)
        case .recurring(let frequency, let time, let dayOfWeek, let dayOfMonth, let timezone):
            try container.encode("recurring", forKey: .type)
            try container.encode(frequency, forKey: .frequency)
            try container.encode(time, forKey: .time)
            try container.encodeIfPresent(dayOfWeek, forKey: .dayOfWeek)
            try container.encodeIfPresent(dayOfMonth, forKey: .dayOfMonth)
            try container.encode(timezone, forKey: .timezone)
        }
    }

    /// Human-readable summary of the schedule (English).
    var summary: String { localizedSummary(language: "") }

    /// Localized human-readable summary of the schedule.
    func localizedSummary(language: String) -> String {
        switch self {
        case .once(let at):
            if let date = ISO8601DateFormatter().date(from: at) {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                if !language.isEmpty {
                    formatter.locale = Locale(identifier: language)
                }
                return formatter.string(from: date)
            }
            return at
        case .recurring(let frequency, let time, let dayOfWeek, _, _):
            switch frequency {
            case .daily:
                let fmt = Bundle.localized("schedule_summary_daily", language: language)
                return String(format: fmt, time)
            case .weekly:
                let dayName = dayOfWeek.flatMap { Calendar.current.weekdaySymbols[safe: $0] } ?? ""
                let fmt = Bundle.localized("schedule_summary_weekly", language: language)
                return String(format: fmt, dayName, time)
            case .monthly:
                let fmt = Bundle.localized("schedule_summary_monthly", language: language)
                return String(format: fmt, time)
            }
        }
    }
}

enum TaskFrequency: String, Codable, CaseIterable, Equatable {
    case daily, weekly, monthly

    var displayName: String {
        rawValue.capitalized
    }
}

// Safe array subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
