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

    static let `default` = BlockedCandleShortStrategy().definition.defaultConfig
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

    func strategy(id: String) -> (any TradingStrategy)? {
        strategies[id]
    }

    func definition(id: String) -> StrategyDefinition? {
        strategies[id]?.definition
    }

    private static var defaultStrategies: [any TradingStrategy] {
        [
            BlockedCandleLongStrategy(),
            BlockedCandleShortStrategy(),
            MovingAverageAlignmentStrategy(),
            VWMATouchTrendStrategy()
        ]
    }
}

enum TradingDomainError: Error, Equatable {
    case missingEntryPrice
    case missingStopLoss
    case missingTakeProfit
    case strategyNotFound(String)
    case liveTradingDisabled
    case selectedSymbolNotInWatchlist(FuturesSymbol)
    case invalidProtectionPlan(String)
    case protectionOrderRetryExhausted(kind: ExchangeProtectionOrderKind, attempts: Int)
}

struct OrderIntent: Codable, Equatable, Identifiable {
    let id: UUID
    let signal: StrategySignal
    let createdAt: Date
}

struct RiskDecision: Codable, Equatable, Identifiable {
    let id: UUID
    let intentID: UUID
    let isAllowed: Bool
    let reason: String
    let decidedAt: Date
}

struct PaperOrder: Codable, Equatable, Identifiable {
    let id: UUID
    let intentID: UUID
    let symbol: FuturesSymbol
    let side: TradeSide
    let entryPrice: Decimal
    let stopLoss: Decimal
    let takeProfit: Decimal
    let createdAt: Date
}
