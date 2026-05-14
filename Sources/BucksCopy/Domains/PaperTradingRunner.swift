import Foundation

final class PaperTradingRunner {
    private let strategyRegistry: StrategyRegistry
    private let logStore: TradeEventLogStore
    private let clock: Clock

    init(
        strategyRegistry: StrategyRegistry,
        logStore: TradeEventLogStore,
        clock: Clock = SystemClock()
    ) {
        self.strategyRegistry = strategyRegistry
        self.logStore = logStore
        self.clock = clock
    }

    func start(
        symbol: FuturesSymbol,
        watchlist: [FuturesSymbol],
        timeframe: CandleTimeframe,
        candles: [Candle],
        config: StrategyConfig
    ) throws -> StrategyEvaluation {
        guard watchlist.contains(symbol) else {
            throw TradingDomainError.selectedSymbolNotInWatchlist(symbol)
        }
        guard let strategy = strategyRegistry.strategy(id: config.strategyID) else {
            throw TradingDomainError.strategyNotFound(config.strategyID)
        }

        let context = StrategyContext(
            symbol: symbol,
            timeframe: timeframe,
            closedCandles: candles.filter(\.isClosed),
            generatedAt: clock.now
        )
        let evaluation = try strategy.evaluate(context, config: config)

        switch evaluation {
        case .noSignal:
            break
        case .signal(let signal):
            let riskDecision = StrategyRiskPolicy.decision(
                for: signal,
                leverage: config.leverage,
                decidedAt: clock.now
            )
            guard riskDecision.isAllowed else {
                try logStore.append(TradeEventLog(
                    timestamp: clock.now,
                    category: .risk,
                    severity: .warning,
                    symbol: signal.symbol,
                    message: riskDecision.reason
                ))
                return .noSignal
            }

            try logStore.append(TradeEventLog(
                timestamp: clock.now,
                category: .paperOrder,
                symbol: signal.symbol,
                message: "Paper \(signal.side.rawValue) order created by \(signal.strategyID). Entry \(signal.entryPrice), stop loss \(signal.stopLoss), take profit \(signal.takeProfit), leverage \(config.leverage)x, reward/risk \(signal.plannedRewardRiskRatio?.riskText ?? "-"):1, leveraged stop risk \(signal.leveragedStopLossPercent(leverage: config.leverage)?.riskText ?? "-")%, TP fee \(TradingFeePolicy.marketEntryTakeProfitLimitFeePercent(leverage: config.leverage).riskText)%, SL fee \(TradingFeePolicy.marketEntryStopLossMarketFeePercent(leverage: config.leverage).riskText)%. Reason: \(signal.reason)"
            ))
        }

        return evaluation
    }
}
