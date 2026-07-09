import Foundation

public struct UsageSummary: Identifiable, Decodable, Equatable, Sendable {
    public let day: String
    public let providerId: String
    public let model: String
    public let requests: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let durationMs: Int

    public var id: String {
        "\(day)-\(providerId)-\(model)"
    }

    public init(day: String, providerId: String, model: String, requests: Int, inputTokens: Int, outputTokens: Int, totalTokens: Int, durationMs: Int) {
        self.day = day
        self.providerId = providerId
        self.model = model
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.durationMs = durationMs
    }

    private enum CodingKeys: String, CodingKey {
        case day
        case providerId = "provider_id"
        case model
        case requests
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case durationMs = "duration_ms"
    }
}

public enum UsageActivityRange: String, CaseIterable, Sendable {
    case sevenDays = "7D"
    case oneMonth = "1M"
    case oneYear = "1Y"

    var dayCount: Int {
        switch self {
        case .sevenDays: 7
        case .oneMonth: 30
        case .oneYear: 365
        }
    }
}

public struct UsageProviderRollup: Equatable, Sendable {
    public let name: String
    public let requests: Int
    public let tokens: Int
    public let topModel: String
    public let lastActiveDay: String
}

public struct UsageModelRollup: Equatable, Sendable {
    public let model: String
    public let providerId: String
    public let todayTokens: Int
    public let sevenDayTokens: Int
    public let allTimeTokens: Int
    public let requests: Int
}

public struct UsageActivityBucket: Identifiable, Equatable, Sendable {
    public let day: String
    public let label: String
    public let tokens: Int

    public var id: String { label }
    public var isActive: Bool { tokens > 0 }
}

public struct UsageAnalytics: Equatable, Sendable {
    public let summaries: [UsageSummary]
    public let today: String

    public init(_ summaries: [UsageSummary], today: String = UsageAnalytics.todayString()) {
        self.summaries = summaries
        self.today = today
    }

    public var todayTokens: Int {
        summaries.filter { $0.day == today }.reduce(0) { $0 + $1.totalTokens }
    }

    public var sevenDayTokens: Int {
        summaries.filter { isInLastDays($0.day, days: 7) }.reduce(0) { $0 + $1.totalTokens }
    }

    public var allTimeTokens: Int {
        summaries.reduce(0) { $0 + $1.totalTokens }
    }

    public var requestCount: Int {
        summaries.reduce(0) { $0 + $1.requests }
    }

    public var activeDayCount: Int {
        Set(summaries.filter { $0.requests > 0 }.map(\.day)).count
    }

    public var topModelSevenDays: String? {
        topModel(in: summaries.filter { isInLastDays($0.day, days: 7) })
    }

    public var costLabel: String {
        "Cost unavailable"
    }

    public var providerRollups: [UsageProviderRollup] {
        let groups = Dictionary(grouping: summaries) { Self.providerGroupName($0.providerId) }
        return ["Official Codex / OpenAI", "Third-party providers"].compactMap { name in
            guard let rows = groups[name], !rows.isEmpty else { return nil }
            return UsageProviderRollup(
                name: name,
                requests: rows.reduce(0) { $0 + $1.requests },
                tokens: rows.reduce(0) { $0 + $1.totalTokens },
                topModel: topModel(in: rows) ?? "n/a",
                lastActiveDay: rows.map(\.day).max() ?? "n/a"
            )
        }
    }

    public var modelRollups: [UsageModelRollup] {
        let groups = Dictionary(grouping: summaries) { "\($0.providerId)\u{0}\($0.model)" }
        return groups.values.map { rows in
            let first = rows[0]
            return UsageModelRollup(
                model: first.model,
                providerId: first.providerId,
                todayTokens: rows.filter { $0.day == today }.reduce(0) { $0 + $1.totalTokens },
                sevenDayTokens: rows.filter { isInLastDays($0.day, days: 7) }.reduce(0) { $0 + $1.totalTokens },
                allTimeTokens: rows.reduce(0) { $0 + $1.totalTokens },
                requests: rows.reduce(0) { $0 + $1.requests }
            )
        }
        .sorted { lhs, rhs in
            if lhs.allTimeTokens != rhs.allTimeTokens {
                return lhs.allTimeTokens > rhs.allTimeTokens
            }
            return lhs.model < rhs.model
        }
    }

    public func activityBuckets(range: UsageActivityRange) -> [UsageActivityBucket] {
        let totals = Dictionary(grouping: summaries, by: \.day).mapValues { rows in
            rows.reduce(0) { $0 + $1.totalTokens }
        }
        switch range {
        case .sevenDays:
            return Self.days(endingAt: today, count: 7).flatMap { day in
                [
                    UsageActivityBucket(day: day, label: "\(day) AM", tokens: totals[day] ?? 0),
                    UsageActivityBucket(day: day, label: "\(day) PM", tokens: 0),
                ]
            }
        case .oneMonth:
            return Self.days(endingAt: today, count: 30).map { day in
                UsageActivityBucket(day: day, label: day, tokens: totals[day] ?? 0)
            }
        case .oneYear:
            return (0..<53).map { index in
                let startOffset = -(((52 - index) * 7) + 6)
                let endOffset = -((52 - index) * 7)
                let start = Self.offsetDay(today, by: startOffset) ?? today
                let end = Self.offsetDay(today, by: endOffset) ?? today
                let tokens = Self.days(from: start, through: end).reduce(0) { $0 + (totals[$1] ?? 0) }
                return UsageActivityBucket(day: start, label: "\(start) - \(end)", tokens: tokens)
            }
        }
    }

    public func activityUnitLabel(range: UsageActivityRange) -> String {
        switch range {
        case .sevenDays: "7D · half-day"
        case .oneMonth: "1M · daily"
        case .oneYear: "1Y · weekly"
        }
    }

    public static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return compact(Double(value) / 1_000_000_000, suffix: "B")
        }
        if value >= 1_000_000 {
            return compact(Double(value) / 1_000_000, suffix: "M")
        }
        if value >= 1_000 {
            return compact(Double(value) / 1_000, suffix: "K")
        }
        return "\(value)"
    }

    public static func readableModelName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    private func isInLastDays(_ day: String, days: Int) -> Bool {
        guard let start = Self.offsetDay(today, by: -(days - 1)) else {
            return day <= today
        }
        return day >= start && day <= today
    }

    private func topModel(in rows: [UsageSummary]) -> String? {
        let totals = Dictionary(grouping: rows, by: \.model).mapValues { rows in
            rows.reduce(0) { $0 + $1.totalTokens }
        }
        return totals.sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            return lhs.key < rhs.key
        }.first?.key
    }

    private static func providerGroupName(_ providerId: String) -> String {
        let clean = providerId.lowercased()
        if clean == "openai" || clean.contains("official") {
            return "Official Codex / OpenAI"
        }
        return "Third-party providers"
    }

    private static func days(endingAt day: String, count: Int) -> [String] {
        (0..<count).compactMap { offsetDay(day, by: -((count - 1) - $0)) }
    }

    private static func days(from start: String, through end: String) -> [String] {
        guard let startDate = parseDay(start),
              let endDate = parseDay(end),
              startDate <= endDate else {
            return []
        }
        var out: [String] = []
        var current = startDate
        while current <= endDate {
            out.append(formatDay(current))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return out
    }

    private static func offsetDay(_ day: String, by offset: Int) -> String? {
        guard let date = parseDay(day),
              let shifted = calendar.date(byAdding: .day, value: offset, to: date) else {
            return nil
        }
        return formatDay(shifted)
    }

    public static func todayString() -> String {
        formatDay(Date())
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))\(suffix)"
        }
        return String(format: "%.1f%@", rounded, suffix)
    }

    private static func parseDay(_ day: String) -> Date? {
        dayFormatter.date(from: day)
    }

    private static func formatDay(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
