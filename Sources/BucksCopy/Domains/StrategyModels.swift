import Foundation

enum TradeSide: String, Codable, Equatable {
    case buy
    case sell
}

struct StrategyDefinition: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let summary: String
    let defaultConfig: StrategyConfig
}

struct StrategyConfig: Codable, Equatable {
    var strategyID: String
    var leverage: Int
    var parameters: [String: Decimal]
    var maximumRiskPerTradePercent: Decimal
    var maximumPositionMarginPercent: Decimal
    var maximumHoldingCandles: Int?
    var signalConfirmation: SignalConfirmationConfig

    static let `default` = BTCFifteenMinuteVacuumPulseStrategy().definition.defaultConfig

    init(
        strategyID: String,
        leverage: Int,
        parameters: [String: Decimal],
        maximumRiskPerTradePercent: Decimal = StrategyRiskPolicy.defaultMaximumRiskPerTradePercent,
        maximumPositionMarginPercent: Decimal = StrategyRiskPolicy.defaultMaximumPositionMarginPercent,
        maximumHoldingCandles: Int? = nil,
        signalConfirmation: SignalConfirmationConfig = .optimizedDefault
    ) {
        self.strategyID = strategyID
        self.leverage = leverage
        self.parameters = parameters
        self.maximumRiskPerTradePercent = maximumRiskPerTradePercent
        self.maximumPositionMarginPercent = maximumPositionMarginPercent
        self.maximumHoldingCandles = maximumHoldingCandles
        self.signalConfirmation = signalConfirmation
    }
}

struct StrategyContext: Equatable {
    let symbol: FuturesSymbol
    let timeframe: CandleTimeframe
    let closedCandles: [Candle]
    let generatedAt: Date
}

struct StrategySignal: Codable, Equatable, Identifiable {
    let id: UUID
    let strategyID: String
    let symbol: FuturesSymbol
    let side: TradeSide
    let entryPrice: Decimal
    let stopLoss: Decimal
    let takeProfit: Decimal
    let reason: String
    let generatedAt: Date
}

struct StrategySignalDraft {
    let strategyID: String
    let symbol: FuturesSymbol
    let side: TradeSide
    let entryPrice: Decimal?
    let stopLoss: Decimal?
    let takeProfit: Decimal?
    let reason: String
    let generatedAt: Date

    func validated() throws -> StrategySignal {
        guard let entryPrice else {
            throw TradingDomainError.missingEntryPrice
        }
        guard let stopLoss else {
            throw TradingDomainError.missingStopLoss
        }
        guard let takeProfit else {
            throw TradingDomainError.missingTakeProfit
        }

        return StrategySignal(
            id: UUID(),
            strategyID: strategyID,
            symbol: symbol,
            side: side,
            entryPrice: entryPrice,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            reason: reason,
            generatedAt: generatedAt
        )
    }
}

enum StrategyEvaluation: Equatable {
    case noSignal
    case signal(StrategySignal)
}

protocol TradingStrategy {
    var definition: StrategyDefinition { get }
    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation
}

struct StrategyRegistry {
    private let strategies: [String: any TradingStrategy]

    init(strategies: [any TradingStrategy] = StrategyRegistry.defaultStrategies) {
        self.strategies = Dictionary(uniqueKeysWithValues: strategies.map { ($0.definition.id, $0) })
    }

    var definitions: [StrategyDefinition] {
        strategies.values.map(\.definition).sorted { $0.name < $1.name }
    }

    func definitions(recommendedFor timeframe: CandleTimeframe) -> [StrategyDefinition] {
        recommendedDefinitions(for: timeframe, symbol: nil)
    }

    func definitions(recommendedFor timeframe: CandleTimeframe, symbol: FuturesSymbol) -> [StrategyDefinition] {
        recommendedDefinitions(for: timeframe, symbol: symbol)
    }

    private func recommendedDefinitions(
        for timeframe: CandleTimeframe,
        symbol: FuturesSymbol?
    ) -> [StrategyDefinition] {
        let strategyIDs = StrategyTimeframeRouting.recommendedStrategyIDs(for: timeframe, symbol: symbol)
        return strategyIDs.compactMap { strategies[$0]?.definition }
    }

    func strategy(id: String) -> (any TradingStrategy)? {
        strategies[id]
    }

    func definition(id: String) -> StrategyDefinition? {
        strategies[id]?.definition
    }

    private static var defaultStrategies: [any TradingStrategy] {
        [
            DonchianChannelBreakoutStrategy(),
            TimeSeriesMomentumStrategy(),
            VWMATouchTrendStrategy(),
            ETHOneHourMomentumBurstStrategy(),
            ETHFifteenMinuteVacuumPulseStrategy(),
            XOneHourLongStrategy(),
            XOneHourShortStrategy(),
            BTCFifteenMinutePhaseVacuumReclaimStrategy(),
            BTCFifteenMinuteVacuumPulseStrategy(),
            BTCFifteenMinuteRegimeSessionFadeStrategy(),
            BTCFifteenMinuteBullPullbackLongStrategy(),
            XFrequencyStrategy(),
            XStrategy()
        ]
    }
}

enum StrategyTimeframeRouting {
    static func recommendedStrategyIDs(
        for timeframe: CandleTimeframe,
        symbol: FuturesSymbol? = nil
    ) -> [String] {
        let baseIDs: [String]
        switch timeframe {
        case .fifteenMinutes:
            baseIDs = [
                XStrategy.identifier,
                XFrequencyStrategy.identifier,
                BTCFifteenMinutePhaseVacuumReclaimStrategy.identifier,
                BTCFifteenMinuteVacuumPulseStrategy.identifier,
                BTCFifteenMinuteRegimeSessionFadeStrategy.identifier,
                BTCFifteenMinuteBullPullbackLongStrategy.identifier,
                ETHFifteenMinuteVacuumPulseStrategy.identifier
            ]
        case .oneHour:
            baseIDs = [
                ETHOneHourMomentumBurstStrategy.identifier
            ]
        case .fourHours:
            baseIDs = [
                DonchianChannelBreakoutStrategy.identifier
            ]
        case .twelveHours:
            baseIDs = [
                VWMATouchTrendStrategy.identifier,
                DonchianChannelBreakoutStrategy.identifier,
                TimeSeriesMomentumStrategy.identifier
            ]
        case .oneDay:
            baseIDs = [
                VWMATouchTrendStrategy.identifier,
                DonchianChannelBreakoutStrategy.identifier
            ]
        }

        guard let symbol else { return baseIDs }
        return baseIDs.filter { strategyID in
            let route = StrategyRouteKey(symbol: symbol, timeframe: timeframe, strategyID: strategyID)
            if symbolScopedLiveRoutes.contains(where: {
                $0.timeframe == timeframe && $0.strategyID == strategyID
            }) {
                return symbolScopedLiveRoutes.contains(route)
            }
            return !blockedLiveRoutes.contains(route)
        }
    }

    static func isRecommended(
        strategyID: String,
        for timeframe: CandleTimeframe,
        symbol: FuturesSymbol? = nil
    ) -> Bool {
        recommendedStrategyIDs(for: timeframe, symbol: symbol).contains(strategyID)
    }

    private static let blockedLiveRoutes: Set<StrategyRouteKey> = [
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .oneHour,
            strategyID: ETHOneHourMomentumBurstStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fourHours,
            strategyID: DonchianChannelBreakoutStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            strategyID: XStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            strategyID: XFrequencyStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .twelveHours,
            strategyID: VWMATouchTrendStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .twelveHours,
            strategyID: DonchianChannelBreakoutStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .twelveHours,
            strategyID: TimeSeriesMomentumStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .oneDay,
            strategyID: DonchianChannelBreakoutStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .oneDay,
            strategyID: VWMATouchTrendStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .oneHour,
            strategyID: ETHOneHourMomentumBurstStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .fifteenMinutes,
            strategyID: XStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .fifteenMinutes,
            strategyID: XFrequencyStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .fifteenMinutes,
            strategyID: BTCFifteenMinutePhaseVacuumReclaimStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .fifteenMinutes,
            strategyID: BTCFifteenMinuteRegimeSessionFadeStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .fifteenMinutes,
            strategyID: BTCFifteenMinuteBullPullbackLongStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .fourHours,
            strategyID: DonchianChannelBreakoutStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .twelveHours,
            strategyID: VWMATouchTrendStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .twelveHours,
            strategyID: DonchianChannelBreakoutStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .twelveHours,
            strategyID: TimeSeriesMomentumStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .oneDay,
            strategyID: VWMATouchTrendStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .oneDay,
            strategyID: DonchianChannelBreakoutStrategy.identifier
        )
    ]

    private static let symbolScopedLiveRoutes: Set<StrategyRouteKey> = [
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            strategyID: BTCFifteenMinutePhaseVacuumReclaimStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            strategyID: BTCFifteenMinuteVacuumPulseStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            strategyID: BTCFifteenMinuteRegimeSessionFadeStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            strategyID: BTCFifteenMinuteBullPullbackLongStrategy.identifier
        ),
        StrategyRouteKey(
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .fifteenMinutes,
            strategyID: ETHFifteenMinuteVacuumPulseStrategy.identifier
        )
    ]
}

private struct StrategyRouteKey: Hashable {
    let symbol: FuturesSymbol
    let timeframe: CandleTimeframe
    let strategyID: String
}

enum TradingDomainError: Error, Equatable, CustomStringConvertible {
    case missingEntryPrice
    case missingStopLoss
    case missingTakeProfit
    case strategyNotFound(String)
    case liveTradingDisabled
    case selectedSymbolNotInWatchlist(FuturesSymbol)
    case missingAccountEquity
    case missingContractSpec(FuturesSymbol)
    case liveOrderSizeTooSmall(FuturesSymbol)
    case liveOrderFillNotConfirmed(String)
    case liveEntryPositionNotConfirmed(String)
    case invalidProtectionPlan(String)
    case protectionOrderRetryExhausted(kind: ExchangeProtectionOrderKind, attempts: Int, cause: String? = nil)

    var description: String {
        switch self {
        case .missingEntryPrice:
            return "missing entry price"
        case .missingStopLoss:
            return "missing stop loss"
        case .missingTakeProfit:
            return "missing take profit"
        case .strategyNotFound(let strategyID):
            return "strategy not found: \(strategyID)"
        case .liveTradingDisabled:
            return "live trading disabled"
        case .selectedSymbolNotInWatchlist(let symbol):
            return "selected symbol not in Watchlist: \(symbol.rawValue)"
        case .missingAccountEquity:
            return "missing account equity"
        case .missingContractSpec(let symbol):
            return "missing contract spec: \(symbol.rawValue)"
        case .liveOrderSizeTooSmall(let symbol):
            return "live order size too small: \(symbol.rawValue)"
        case .liveOrderFillNotConfirmed(let clientOid):
            return "live order fill not confirmed: \(TradeLogRedaction.identifier(clientOid))"
        case .liveEntryPositionNotConfirmed(let clientOid):
            return "live entry position not confirmed after fill receipt: \(TradeLogRedaction.identifier(clientOid))"
        case .invalidProtectionPlan(let reason):
            return "invalid protection plan: \(reason)"
        case .protectionOrderRetryExhausted(let kind, let attempts, let cause):
            let causeText = cause.map { ", cause \($0)" } ?? ""
            return "protection order retry exhausted: \(kind.rawValue), attempts \(attempts)\(causeText)"
        }
    }
}

protocol PublicTradingErrorDescribing {
    var tradingLogDescription: String { get }
}

struct OrderIntent: Codable, Equatable, Identifiable {
    let id: UUID
    let signal: StrategySignal
    let createdAt: Date
}

enum LiveOrderPurpose: String, Codable, Equatable {
    case open
    case close
}

enum LiveOrderStatus: String, Codable, Equatable {
    case live
    case partiallyFilled = "partially_filled"
    case filled
    case canceled
    case unknown
}

struct LiveOrderRequest: Codable, Equatable, Identifiable {
    let id: UUID
    let symbol: FuturesSymbol
    let side: TradeSide
    let purpose: LiveOrderPurpose
    let size: Decimal
    let leverage: Int
    let marginMode: String
    let marginCoin: String
    let reduceOnly: Bool
    let clientOid: String

    init(
        id: UUID = UUID(),
        symbol: FuturesSymbol,
        side: TradeSide,
        purpose: LiveOrderPurpose,
        size: Decimal,
        leverage: Int,
        marginMode: String = "isolated",
        marginCoin: String = "USDT",
        reduceOnly: Bool = false,
        clientOid: String? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.side = side
        self.purpose = purpose
        self.size = size
        self.leverage = leverage
        self.marginMode = marginMode
        self.marginCoin = marginCoin
        self.reduceOnly = reduceOnly
        self.clientOid = clientOid ?? "bc-\(id.uuidString.lowercased())"
    }
}

struct LiveOrderReceipt: Codable, Equatable {
    let orderID: String
    let clientOid: String
    let symbol: FuturesSymbol
    let status: LiveOrderStatus
    let filledSize: Decimal?
    let averagePrice: Decimal?
}

struct LiveClosePositionReceipt: Codable, Equatable {
    let symbol: FuturesSymbol
    let orderIDs: [String]
}

struct RiskDecision: Codable, Equatable, Identifiable {
    let id: UUID
    let intentID: UUID
    let isAllowed: Bool
    let reason: String
    let positionMarginRatio: Decimal
    let accountRiskPercent: Decimal
    let decidedAt: Date
}

struct LiveOrderRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let intentID: UUID
    let symbol: FuturesSymbol
    let side: TradeSide
    let entryPrice: Decimal
    let stopLoss: Decimal
    let takeProfit: Decimal
    let createdAt: Date
}

struct PositionHoldingPeriodExit: Equatable {
    let position: PositionSnapshot
    let strategyID: String
    let timeframe: CandleTimeframe
    let enteredAt: Date
    let maximumHoldingCandles: Int
    let elapsedCandles: Int
    let reason: String

    var maximumHoldingDuration: TimeInterval {
        timeframe.duration * Double(maximumHoldingCandles)
    }
}
