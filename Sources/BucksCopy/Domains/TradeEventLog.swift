import Foundation

enum TradeEventCategory: String, Codable, CaseIterable {
    case automation
    case bot
    case credential
    case signal
    case liveOrder
    case risk
    case position
}

enum TradeEventSeverity: String, Codable, CaseIterable {
    case info
    case warning
    case error
}

enum TradeLogLanguage: String, Codable, CaseIterable, Identifiable, Equatable {
    case korean
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .korean:
            return "한국어"
        case .english:
            return "English"
        }
    }
}

enum TradeLogTone: String, Codable, Equatable {
    case neutral
    case accent
    case success
    case warning
    case danger
}

struct TradeLogTag: Codable, Equatable, Identifiable {
    let label: String
    let tone: TradeLogTone

    var id: String { "\(label):\(tone.rawValue)" }

    init(label: String, tone: TradeLogTone = .neutral) {
        self.label = label
        self.tone = tone
    }
}

struct TradeLogDetail: Codable, Equatable, Identifiable {
    let label: String
    let value: String
    let tone: TradeLogTone

    var id: String { "\(label):\(value)" }

    init(label: String, value: String, tone: TradeLogTone = .neutral) {
        self.label = label
        self.value = value
        self.tone = tone
    }
}

struct TradeLogMetadata: Codable, Equatable {
    let title: String
    let subtitle: String?
    let tags: [TradeLogTag]
    let details: [TradeLogDetail]

    init(
        title: String,
        subtitle: String? = nil,
        tags: [TradeLogTag] = [],
        details: [TradeLogDetail] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tags = tags
        self.details = details
    }
}

struct TradeEventLog: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: TradeEventCategory
    let severity: TradeEventSeverity
    let symbol: FuturesSymbol?
    let message: String
    let metadata: TradeLogMetadata?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: TradeEventCategory,
        severity: TradeEventSeverity = .info,
        symbol: FuturesSymbol? = nil,
        message: String,
        metadata: TradeLogMetadata? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.severity = severity
        self.symbol = symbol
        self.message = message
        self.metadata = metadata
    }

    var isPersistentTradingRecord: Bool {
        switch category {
        case .automation, .signal, .liveOrder, .risk:
            return true
        case .bot, .credential, .position:
            return false
        }
    }

    var isAutomationTradingRecord: Bool {
        switch category {
        case .automation, .signal, .liveOrder, .risk:
            return true
        case .bot, .credential, .position:
            return false
        }
    }
}

enum TradeLogRedaction {
    static func identifier(_ value: String) -> String {
        guard !value.isEmpty else { return "-" }
        guard value.count > 8 else { return "****" }
        let suffix = value.suffix(6)
        return "****\(suffix)"
    }
}
