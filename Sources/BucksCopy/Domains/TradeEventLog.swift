import Foundation

enum TradeEventCategory: String, Codable, CaseIterable {
    case bot
    case credential
    case signal
    case paperOrder
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

struct TradeEventLog: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: TradeEventCategory
    let severity: TradeEventSeverity
    let symbol: FuturesSymbol?
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: TradeEventCategory,
        severity: TradeEventSeverity = .info,
        symbol: FuturesSymbol? = nil,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.severity = severity
        self.symbol = symbol
        self.message = message
    }

    var isPersistentTradingRecord: Bool {
        switch category {
        case .signal, .paperOrder, .risk:
            return true
        case .bot, .credential, .position:
            return false
        }
    }
}
