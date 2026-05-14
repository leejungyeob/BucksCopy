import Foundation

final class PaperTradingRunner {
    private let strategyRegistry: StrategyRegistry
    private let logStore: TradeEventLogStore
    private let confirmationEngine: SignalConfirmationEngine
    private let clock: Clock

    init(
        strategyRegistry: StrategyRegistry,
        logStore: TradeEventLogStore,
        confirmationEngine: SignalConfirmationEngine = SignalConfirmationEngine(),
        clock: Clock = SystemClock()
    ) {
        self.strategyRegistry = strategyRegistry
        self.logStore = logStore
        self.confirmationEngine = confirmationEngine
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
            let confirmationDecision: SignalConfirmationDecision
            if let profile = SignalConfirmationProfile.researchDefault(
                strategyID: config.strategyID,
                timeframe: timeframe
            ) {
                confirmationDecision = confirmationEngine.decision(
                    for: signal,
                    context: context,
                    config: config.signalConfirmation,
                    profile: profile
                )
            } else {
                confirmationDecision = confirmationEngine.decision(
                    for: signal,
                    context: context,
                    config: config.signalConfirmation
                )
            }
            guard confirmationDecision.isAllowed else {
                try logStore.append(TradeEventLog(
                    timestamp: clock.now,
                    category: .signal,
                    severity: .warning,
                    symbol: signal.symbol,
                    message: confirmationDecision.reason
                ))
                return .noSignal
            }

            let confirmedSignal = signal.addingConfirmation(confirmationDecision.score)
            let riskDecision = StrategyRiskPolicy.decision(
                for: confirmedSignal,
                leverage: config.leverage,
                maximumRiskPerTradePercent: config.maximumRiskPerTradePercent *
                    confirmationDecision.maximumRiskPerTradeMultiplier,
                maximumPositionMarginPercent: config.maximumPositionMarginPercent,
                decidedAt: clock.now
            )
            guard riskDecision.isAllowed else {
                try logStore.append(TradeEventLog(
                    timestamp: clock.now,
                    category: .risk,
                    severity: .warning,
                    symbol: confirmedSignal.symbol,
                    message: riskDecision.reason
                ))
                return .noSignal
            }

            try logStore.append(TradeEventLog(
                timestamp: clock.now,
                category: .paperOrder,
                symbol: confirmedSignal.symbol,
                message: "Paper \(confirmedSignal.side.rawValue) order created by \(confirmedSignal.strategyID) on \(timeframe.rawValue). Entry \(confirmedSignal.entryPrice), stop loss \(confirmedSignal.stopLoss), take profit \(confirmedSignal.takeProfit), leverage \(config.leverage)x, margin \((riskDecision.positionMarginRatio * 100).riskText)%, account risk \(riskDecision.accountRiskPercent.riskText)%, reward/risk \(confirmedSignal.plannedRewardRiskRatio?.riskText ?? "-"):1, TP fee \(TradingFeePolicy.marketEntryTakeProfitLimitFeePercent(leverage: config.leverage, positionMarginRatio: riskDecision.positionMarginRatio).riskText)%, SL fee \(TradingFeePolicy.marketEntryStopLossMarketFeePercent(leverage: config.leverage, positionMarginRatio: riskDecision.positionMarginRatio).riskText)%. Reason: \(confirmedSignal.reason)"
            ))
        }

        return evaluation
    }
}
