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

    static let dashboardCases: [CandleTimeframe] = [.fifteenMinutes]
    static let marketDataSyncCases: [CandleTimeframe] = [.fifteenMinutes]
    static let liveTradingCases: [CandleTimeframe] = [.fifteenMinutes]

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

enum PositionMode: String, Codable, Equatable {
    case hedge = "hedge_mode"
    case oneWay = "one_way_mode"
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
    let positionMode: PositionMode
    let liquidationPrice: Decimal?
    let partialTakeProfit: Decimal?
    let takeProfit: Decimal?
    let stopLoss: Decimal?
    let createdAt: Date?
    let updatedAt: Date?

    var id: String { "\(symbol.rawValue):\(side.rawValue)" }

    init(
        symbol: FuturesSymbol,
        side: PositionSide,
        total: Decimal,
        available: Decimal,
        openPriceAverage: Decimal,
        markPrice: Decimal,
        unrealizedProfitLoss: Decimal,
        leverage: Int,
        marginMode: String,
        positionMode: PositionMode = .unknown,
        liquidationPrice: Decimal?,
        partialTakeProfit: Decimal? = nil,
        takeProfit: Decimal?,
        stopLoss: Decimal?,
        createdAt: Date?,
        updatedAt: Date?
    ) {
        self.symbol = symbol
        self.side = side
        self.total = total
        self.available = available
        self.openPriceAverage = openPriceAverage
        self.markPrice = markPrice
        self.unrealizedProfitLoss = unrealizedProfitLoss
        self.leverage = leverage
        self.marginMode = marginMode
        self.positionMode = positionMode
        self.liquidationPrice = liquidationPrice
        self.partialTakeProfit = partialTakeProfit
        self.takeProfit = takeProfit
        self.stopLoss = stopLoss
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

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
    case runningLive(startedAt: Date)
}

struct BacktestConfiguration: Codable, Equatable {
    var symbol: FuturesSymbol
    var timeframe: CandleTimeframe
    var strategyConfig: StrategyConfig
    var initialCapital: Decimal = 100
    var comparesSignalConfirmation: Bool = false

    static let `default` = BacktestConfiguration(
        symbol: FuturesSymbol("BTCUSDT"),
        timeframe: .fifteenMinutes,
        strategyConfig: StrategyConfig.default,
        initialCapital: 100,
        comparesSignalConfirmation: false
    )
}

enum BacktestStatus: Equatable {
    case idle
    case running(startedAt: Date)
    case complete
    case failed(message: String)
}

enum BacktestTradeOutcome: String, Codable, Equatable {
    case win
    case loss
}

struct BacktestTrade: Codable, Equatable, Identifiable {
    let id: UUID
    let symbol: FuturesSymbol
    let side: TradeSide
    let entryTime: Date
    let exitTime: Date
    let entryPrice: Decimal
    let stopLoss: Decimal
    let takeProfit: Decimal
    let partialTakeProfit: Decimal?
    let exitPrice: Decimal
    let outcome: BacktestTradeOutcome
    let rewardRiskRatio: Decimal
    let leveragedReturnPercent: Decimal
    let leveragedStopLossPercent: Decimal
    let positionMarginRatio: Decimal
    let accountRiskPercent: Decimal
    let partialTakeProfitFillRatio: Decimal
    let finalTakeProfitFillRatio: Decimal
    let stopLossFillRatio: Decimal
    let startingBalance: Decimal
    let endingBalance: Decimal
    let reason: String

    var profitLossAmount: Decimal {
        endingBalance - startingBalance
    }

    init(
        id: UUID = UUID(),
        symbol: FuturesSymbol,
        side: TradeSide,
        entryTime: Date,
        exitTime: Date,
        entryPrice: Decimal,
        stopLoss: Decimal,
        takeProfit: Decimal,
        partialTakeProfit: Decimal? = nil,
        exitPrice: Decimal,
        outcome: BacktestTradeOutcome,
        rewardRiskRatio: Decimal,
        leveragedReturnPercent: Decimal,
        leveragedStopLossPercent: Decimal,
        positionMarginRatio: Decimal = 1,
        accountRiskPercent: Decimal = 0,
        partialTakeProfitFillRatio: Decimal = 0,
        finalTakeProfitFillRatio: Decimal = 0,
        stopLossFillRatio: Decimal = 0,
        startingBalance: Decimal = 0,
        endingBalance: Decimal = 0,
        reason: String
    ) {
        self.id = id
        self.symbol = symbol
        self.side = side
        self.entryTime = entryTime
        self.exitTime = exitTime
        self.entryPrice = entryPrice
        self.stopLoss = stopLoss
        self.takeProfit = takeProfit
        self.partialTakeProfit = partialTakeProfit
        self.exitPrice = exitPrice
        self.outcome = outcome
        self.rewardRiskRatio = rewardRiskRatio
        self.leveragedReturnPercent = leveragedReturnPercent
        self.leveragedStopLossPercent = leveragedStopLossPercent
        self.positionMarginRatio = positionMarginRatio
        self.accountRiskPercent = accountRiskPercent
        self.partialTakeProfitFillRatio = partialTakeProfitFillRatio
        self.finalTakeProfitFillRatio = finalTakeProfitFillRatio
        self.stopLossFillRatio = stopLossFillRatio
        self.startingBalance = startingBalance
        self.endingBalance = endingBalance
        self.reason = reason
    }
}

struct BacktestResult: Codable, Equatable {
    let symbol: FuturesSymbol
    let timeframe: CandleTimeframe
    let strategyID: String
    let leverage: Int
    let totalCandles: Int
    let totalTrades: Int
    let winningTrades: Int
    let losingTrades: Int
    let skippedSignals: Int
    let blockedSignals: Int
    let openSignals: Int
    let confirmationBlockedSignals: Int
    let initialCapital: Decimal
    let finalBalance: Decimal
    let netReturnPercent: Decimal
    let maxDrawdownPercent: Decimal
    let averageRewardRiskRatio: Decimal
    let profitFactor: Decimal
    let blockedSignalSummaries: [BacktestBlockedSignalSummary]
    let confirmationBlockedSignalSummaries: [BacktestBlockedSignalSummary]
    let averageConfirmationScore: Decimal
    let confirmationScoreBuckets: [BacktestConfirmationScoreBucket]
    let trades: [BacktestTrade]
    let completedAt: Date

    var winRatePercent: Decimal {
        guard totalTrades > 0 else { return 0 }
        return Decimal(winningTrades) / Decimal(totalTrades) * 100
    }

    var netProfitAmount: Decimal {
        finalBalance - initialCapital
    }

    var averagePositionMarginPercent: Decimal {
        guard !trades.isEmpty else { return 0 }
        return trades.reduce(Decimal(0)) { $0 + $1.positionMarginRatio * 100 } / Decimal(trades.count)
    }

    var averageAccountRiskPercent: Decimal {
        guard !trades.isEmpty else { return 0 }
        return trades.reduce(Decimal(0)) { $0 + $1.accountRiskPercent } / Decimal(trades.count)
    }
}

struct BacktestBlockedSignalSummary: Codable, Equatable, Identifiable {
    let reason: String
    let count: Int

    var id: String { reason }
}

struct BacktestConfirmationScoreBucket: Codable, Equatable, Identifiable {
    let bucket: SignalConfirmationScoreBucket
    let signalCount: Int
    let tradeCount: Int
    let winningTrades: Int
    let losingTrades: Int
    let confirmationBlockedSignals: Int
    let riskBlockedSignals: Int
    let openSignals: Int
    let netProfitAmount: Decimal
    let netReturnPercent: Decimal
    let averageScore: Decimal

    var id: String { bucket.rawValue }

    var winRatePercent: Decimal {
        guard tradeCount > 0 else { return 0 }
        return Decimal(winningTrades) / Decimal(tradeCount) * 100
    }
}

struct BacktestSignalConfirmationOptimizationCandidate: Codable, Equatable, Identifiable {
    let requiredScore: Decimal
    let totalTrades: Int
    let confirmationBlockedSignals: Int
    let netReturnPercent: Decimal
    let netReturnDeltaPercent: Decimal
    let winRatePercent: Decimal
    let winRateDeltaPercent: Decimal
    let maxDrawdownPercent: Decimal
    let maxDrawdownDeltaPercent: Decimal

    var id: String { requiredScore.riskText }
}

struct BacktestSignalConfirmationOptimizationReport: Codable, Equatable {
    let minimumTradeCount: Int
    let recommendedMode: SignalConfirmationMode
    let recommendedRequiredScore: Decimal?
    let reason: String
    let candidates: [BacktestSignalConfirmationOptimizationCandidate]

    var recommendedCandidate: BacktestSignalConfirmationOptimizationCandidate? {
        guard let recommendedRequiredScore else { return nil }
        return candidates.first { $0.requiredScore == recommendedRequiredScore }
    }

    var recommendationText: String {
        switch recommendedMode {
        case .off:
            return "OFF"
        case .observe:
            return "Observe"
        case .gate:
            guard let recommendedRequiredScore else { return "Gate" }
            return "Gate \(recommendedRequiredScore.riskText)점"
        }
    }
}

struct BacktestComparisonResult: Codable, Equatable {
    let withoutSignalConfirmation: BacktestResult
    let observedSignalConfirmation: BacktestResult
    let withSignalConfirmation: BacktestResult
    let optimizationReport: BacktestSignalConfirmationOptimizationReport

    var netReturnDeltaPercent: Decimal {
        withSignalConfirmation.netReturnPercent - withoutSignalConfirmation.netReturnPercent
    }

    var finalBalanceDelta: Decimal {
        withSignalConfirmation.finalBalance - withoutSignalConfirmation.finalBalance
    }

    var winRateDeltaPercent: Decimal {
        withSignalConfirmation.winRatePercent - withoutSignalConfirmation.winRatePercent
    }

    var tradeCountDelta: Int {
        withSignalConfirmation.totalTrades - withoutSignalConfirmation.totalTrades
    }

    var maxDrawdownDeltaPercent: Decimal {
        withSignalConfirmation.maxDrawdownPercent - withoutSignalConfirmation.maxDrawdownPercent
    }

    var observeNetReturnDeltaPercent: Decimal {
        observedSignalConfirmation.netReturnPercent - withoutSignalConfirmation.netReturnPercent
    }

    var missedUpsidePercentPoints: Decimal {
        tradeImpactSummary.missedUpsidePercentPoints
    }

    var defendedDownsidePercentPoints: Decimal {
        tradeImpactSummary.defendedDownsidePercentPoints
    }

    var missedUpsideTradeCount: Int {
        tradeImpactSummary.missedUpsideTradeCount
    }

    var defendedDownsideTradeCount: Int {
        tradeImpactSummary.defendedDownsideTradeCount
    }

    var netFilteredOutTradeCount: Int {
        rawNetFilteredOutTradeCount
    }

    func primaryResult(mode: SignalConfirmationMode) -> BacktestResult {
        switch mode {
        case .off:
            return withoutSignalConfirmation
        case .observe:
            return observedSignalConfirmation
        case .gate:
            return withSignalConfirmation
        }
    }

    private var tradeImpactSummary: BacktestComparisonTradeImpactSummary {
        let filteredOutTradeCount = rawNetFilteredOutTradeCount
        guard filteredOutTradeCount > 0 else {
            return BacktestComparisonTradeImpactSummary()
        }

        let appliedTradeKeys = Set(withSignalConfirmation.trades.map(BacktestComparisonTradeKey.init))
        let missingBaselineTrades = withoutSignalConfirmation.trades
            .filter { !appliedTradeKeys.contains(BacktestComparisonTradeKey($0)) }
            .sorted { $0.entryTime < $1.entryTime }
            .suffix(filteredOutTradeCount)

        return missingBaselineTrades.reduce(
            into: BacktestComparisonTradeImpactSummary()
        ) { summary, trade in
            let baselineReturn = trade.leveragedReturnPercent
            summary.filteredOutTradeCount += 1

            if baselineReturn > 0 {
                summary.missedUpsidePercentPoints += baselineReturn
                summary.missedUpsideTradeCount += 1
            } else if baselineReturn < 0 {
                summary.defendedDownsidePercentPoints += baselineReturn
                summary.defendedDownsideTradeCount += 1
            }
        }
    }

    private var rawNetFilteredOutTradeCount: Int {
        max(withoutSignalConfirmation.totalTrades - withSignalConfirmation.totalTrades, 0)
    }
}

private struct BacktestComparisonTradeImpactSummary {
    var missedUpsidePercentPoints: Decimal = 0
    var defendedDownsidePercentPoints: Decimal = 0
    var missedUpsideTradeCount = 0
    var defendedDownsideTradeCount = 0
    var filteredOutTradeCount = 0
}

private struct BacktestComparisonTradeKey: Hashable {
    let entryTime: TimeInterval
    let side: String
    let entryPrice: String
    let stopLoss: String
    let takeProfit: String

    init(_ trade: BacktestTrade) {
        entryTime = trade.entryTime.timeIntervalSince1970
        side = trade.side.rawValue
        entryPrice = trade.entryPrice.description
        stopLoss = trade.stopLoss.description
        takeProfit = trade.takeProfit.description
    }
}

struct LiveAutomationSession: Codable, Equatable {
    let startedAt: Date
    var stoppedAt: Date?
    let seedEquity: Decimal?
    let seedAvailable: Decimal?
    var latestEquity: Decimal?
    var latestAvailable: Decimal?
    var latestUnrealizedProfitLoss: Decimal?
    var lastUpdatedAt: Date?

    var isRunning: Bool {
        stoppedAt == nil
    }
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
    var marketDataBootstrapStatus: MarketDataBootstrapStatus = .idle
    var accounts: [AccountSnapshot] = []
    var positions: [PositionSnapshot] = []
    var strategyConfig: StrategyConfig = .default
    var runState: StrategyRunState = .stopped
    var backtestConfiguration: BacktestConfiguration = .default
    var backtestStatus: BacktestStatus = .idle
    var backtestResult: BacktestResult?
    var backtestComparisonResult: BacktestComparisonResult?
    var liveAutomationSession: LiveAutomationSession?
    var automationLogs: [TradeEventLog] = []
    var recentLogs: [TradeEventLog] = []

    var isConnected: Bool {
        if case .connected = credentialStatus {
            return true
        }
        return false
    }

    static let defaultWatchlist: [FuturesSymbol] = [
        "BTCUSDT", "ETHUSDT"
    ].map(FuturesSymbol.init)
}

enum CandleLoadStatus: Equatable {
    case idle
    case loading
    case loaded(count: Int, source: String)
    case failed(message: String)
}

enum MarketDataBootstrapStatus: Equatable {
    case idle
    case syncing(
        completedRoutes: Int,
        totalRoutes: Int,
        currentSymbol: FuturesSymbol,
        currentTimeframe: CandleTimeframe,
        savedCandles: Int,
        currentRouteProgress: Double
    )
    case complete(totalRoutes: Int, skippedRoutes: Int, savedCandles: Int)
    case failed(message: String)

    var progress: Double? {
        switch self {
        case .idle, .failed:
            return nil
        case .syncing(let completedRoutes, let totalRoutes, _, _, _, let currentRouteProgress):
            guard totalRoutes > 0 else { return nil }
            let clampedRouteProgress = min(max(currentRouteProgress, 0), 0.99)
            return (Double(completedRoutes) + clampedRouteProgress) / Double(totalRoutes)
        case .complete:
            return 1
        }
    }
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

    static func string(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
