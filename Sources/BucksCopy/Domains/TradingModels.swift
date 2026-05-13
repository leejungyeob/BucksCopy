import Foundation

enum ProductType: String, Codable, CaseIterable, Equatable {
    case usdtFutures = "USDT-FUTURES"
}

struct FuturesSymbol: Hashable, Codable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    init(_ rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }
}

struct ContractSpec: Codable, Equatable, Identifiable {
    let symbol: FuturesSymbol
    let baseCoin: String
    let quoteCoin: String
    let symbolStatus: String
    let supportMarginCoins: [String]
    let minTradeNum: Decimal
    let minTradeUSDT: Decimal
    let sizeMultiplier: Decimal
    let pricePlace: Int
    let volumePlace: Int
    let minLeverage: Int
    let maxLeverage: Int

    var id: String { symbol.rawValue }

    var isUSDTFuturesTradable: Bool {
        symbolStatus.lowercased() == "normal" &&
            supportMarginCoins.contains { $0.uppercased() == "USDT" }
    }
}

enum CandleTimeframe: String, Codable, CaseIterable, Identifiable {
    case fifteenMinutes = "15m"
    case oneHour = "1H"
    case fourHours = "4H"
    case twelveHours = "12H"
    case oneDay = "1D"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var bitgetGranularity: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .fifteenMinutes:
            return 15 * 60
        case .oneHour:
            return 60 * 60
        case .fourHours:
            return 4 * 60 * 60
        case .twelveHours:
            return 12 * 60 * 60
        case .oneDay:
            return 24 * 60 * 60
        }
    }
}

struct Candle: Codable, Equatable, Identifiable {
    let productType: ProductType
    let symbol: FuturesSymbol
    let timeframe: CandleTimeframe
    let openTime: Date
    let open: Decimal
    let high: Decimal
    let low: Decimal
    let close: Decimal
    let volume: Decimal
    let isClosed: Bool

    var id: String {
        "\(productType.rawValue):\(symbol.rawValue):\(timeframe.rawValue):\(Int(openTime.timeIntervalSince1970))"
    }
}

struct CandleHistorySyncState: Codable, Equatable {
    let productType: ProductType
    let symbol: FuturesSymbol
    let timeframe: CandleTimeframe
    let isComplete: Bool
    let oldestOpenTime: Date?
    let updatedAt: Date
}

enum PositionSide: String, Codable, Equatable {
    case long
    case short
    case unknown
}

struct PositionSnapshot: Codable, Equatable, Identifiable {
    let symbol: FuturesSymbol
    let side: PositionSide
    let total: Decimal
    let available: Decimal
    let openPriceAverage: Decimal
    let markPrice: Decimal
    let unrealizedProfitLoss: Decimal
    let leverage: Int
    let marginMode: String
    let liquidationPrice: Decimal?
    let takeProfit: Decimal?
    let stopLoss: Decimal?
    let createdAt: Date?
    let updatedAt: Date?

    var id: String { "\(symbol.rawValue):\(side.rawValue)" }

    var priceMovePercent: Decimal? {
        guard openPriceAverage > 0 else { return nil }
        let priceDelta: Decimal
        switch side {
        case .long:
            priceDelta = markPrice - openPriceAverage
        case .short:
            priceDelta = openPriceAverage - markPrice
        case .unknown:
            return nil
        }
        return priceDelta / openPriceAverage * 100
    }
}

struct AccountSnapshot: Codable, Equatable, Identifiable {
    let marginCoin: String
    let available: Decimal
    let accountEquity: Decimal
    let unrealizedProfitLoss: Decimal
    let updatedAt: Date

    var id: String { marginCoin }
}

struct APIKeyCredential: Equatable {
    let apiKey: String
    let secretKey: String
    let passphrase: String

    var isComplete: Bool {
        !apiKey.isEmpty && !secretKey.isEmpty && !passphrase.isEmpty
    }

    var redactedIdentifier: String {
        guard apiKey.count > 8 else { return "****" }
        return "\(apiKey.prefix(4))...\(apiKey.suffix(4))"
    }
}

enum CredentialStatus: Equatable {
    case disconnected
    case saved(redactedIdentifier: String)
    case validating(redactedIdentifier: String)
    case connected(redactedIdentifier: String, checkedAt: Date)
    case failed(message: String)
}

enum StrategyRunState: Equatable {
    case stopped
    case runningPaper(startedAt: Date)
}

struct DashboardState: Equatable {
    var credentialStatus: CredentialStatus = .disconnected
    var logLanguage: TradeLogLanguage = .korean
    var symbolCatalog: [ContractSpec] = []
    var watchlist: [FuturesSymbol] = Self.defaultWatchlist
    var selectedSymbol: FuturesSymbol = FuturesSymbol("BTCUSDT")
    var selectedTimeframe: CandleTimeframe = .fifteenMinutes
    var candles: [Candle] = []
    var candleStatus: CandleLoadStatus = .idle
    var candleHistoryStatus: CandleHistoryLoadStatus = .idle
    var accounts: [AccountSnapshot] = []
    var positions: [PositionSnapshot] = []
    var strategyConfig: StrategyConfig = .default
    var runState: StrategyRunState = .stopped
    var recentLogs: [TradeEventLog] = []

    var isConnected: Bool {
        if case .connected = credentialStatus {
            return true
        }
        return false
    }

    static let defaultWatchlist: [FuturesSymbol] = [
        "BTCUSDT", "ETHUSDT", "XRPUSDT", "SOLUSDT", "BNBUSDT", "DOGEUSDT",
        "ADAUSDT", "BCHUSDT", "LTCUSDT", "LINKUSDT", "AVAXUSDT", "TRXUSDT",
        "DOTUSDT", "SUIUSDT", "APTUSDT", "ARBUSDT", "OPUSDT", "NEARUSDT",
        "ETCUSDT", "FILUSDT", "ATOMUSDT", "PEPEUSDT", "WIFUSDT"
    ].map(FuturesSymbol.init)
}

enum CandleLoadStatus: Equatable {
    case idle
    case loading
    case loaded(count: Int, source: String)
    case failed(message: String)
}

enum CandleHistoryLoadStatus: Equatable {
    case idle
    case syncing(savedCount: Int, pageCount: Int)
    case complete(savedCount: Int)
    case failed(message: String)
}

enum DecimalText {
    static func parse(_ value: String?) -> Decimal {
        guard let value, !value.isEmpty else { return 0 }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    static func optional(_ value: String?) -> Decimal? {
        guard let value, !value.isEmpty else { return nil }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }
}
