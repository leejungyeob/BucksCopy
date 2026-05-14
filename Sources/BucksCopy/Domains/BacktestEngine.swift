import Foundation

enum BacktestEngineError: Error, Equatable {
    case insufficientCandles(required: Int, actual: Int)
}

struct BacktestEngine {
    private let strategyRegistry: StrategyRegistry
    private let minimumWarmupCandles = 40

    init(strategyRegistry: StrategyRegistry) {
        self.strategyRegistry = strategyRegistry
    }

    func run(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        candles: [Candle],
        config: StrategyConfig,
        completedAt: Date = Date()
    ) throws -> BacktestResult {
        guard let strategy = strategyRegistry.strategy(id: config.strategyID) else {
            throw TradingDomainError.strategyNotFound(config.strategyID)
        }

        let closedCandles = candles
            .filter { $0.symbol == symbol && $0.timeframe == timeframe && $0.isClosed }
            .sorted { $0.openTime < $1.openTime }

        guard closedCandles.count >= minimumWarmupCandles else {
            throw BacktestEngineError.insufficientCandles(
                required: minimumWarmupCandles,
                actual: closedCandles.count
            )
        }

        var trades: [BacktestTrade] = []
        var skippedSignals = 0
        var blockedSignals = 0
        var openSignals = 0
        var history: [Candle] = []
        history.reserveCapacity(closedCandles.count)

        var index = 0
        while index < closedCandles.count {
            try Task.checkCancellation()
            history.append(closedCandles[index])

            guard history.count >= minimumWarmupCandles else {
                index += 1
                continue
            }

            let context = StrategyContext(
                symbol: symbol,
                timeframe: timeframe,
                closedCandles: history,
                generatedAt: closedCandles[index].openTime
            )

            let evaluation = try strategy.evaluate(context, config: config)
            guard case .signal(let signal) = evaluation else {
                index += 1
                continue
            }

            let riskDecision = StrategyRiskPolicy.decision(
                for: signal,
                leverage: config.leverage,
                decidedAt: closedCandles[index].openTime
            )

            guard riskDecision.isAllowed else {
                blockedSignals += 1
                index += 1
                continue
            }

            guard let exit = simulatedExit(
                signal: signal,
                candles: closedCandles,
                startingAt: index + 1,
                leverage: config.leverage
            ) else {
                openSignals += 1
                index += 1
                continue
            }

            trades.append(exit.trade)
            index = max(exit.exitIndex + 1, index + 1)
        }

        let winningTrades = trades.filter { $0.outcome == .win }.count
        let losingTrades = trades.filter { $0.outcome == .loss }.count
        skippedSignals += openSignals

        return BacktestResult(
            symbol: symbol,
            timeframe: timeframe,
            strategyID: config.strategyID,
            leverage: config.leverage,
            totalCandles: closedCandles.count,
            totalTrades: trades.count,
            winningTrades: winningTrades,
            losingTrades: losingTrades,
            skippedSignals: skippedSignals,
            blockedSignals: blockedSignals,
            openSignals: openSignals,
            netReturnPercent: trades.netReturnPercent,
            maxDrawdownPercent: trades.maxDrawdownPercent,
            averageRewardRiskRatio: trades.averageRewardRiskRatio,
            profitFactor: trades.profitFactor,
            trades: trades,
            completedAt: completedAt
        )
    }

    private func simulatedExit(
        signal: StrategySignal,
        candles: [Candle],
        startingAt startIndex: Int,
        leverage: Int
    ) -> (trade: BacktestTrade, exitIndex: Int)? {
        guard startIndex < candles.count else { return nil }

        for index in startIndex..<candles.count {
            let candle = candles[index]
            let hitStop: Bool
            let hitTake: Bool

            switch signal.side {
            case .buy:
                hitStop = candle.low <= signal.stopLoss
                hitTake = candle.high >= signal.takeProfit
            case .sell:
                hitStop = candle.high >= signal.stopLoss
                hitTake = candle.low <= signal.takeProfit
            }

            guard hitStop || hitTake else { continue }

            let outcome: BacktestTradeOutcome = hitStop ? .loss : .win
            let exitPrice = hitStop ? signal.stopLoss : signal.takeProfit
            let grossReturnPercent = leveragedReturnPercent(
                side: signal.side,
                entryPrice: signal.entryPrice,
                exitPrice: exitPrice,
                leverage: leverage
            )
            let returnPercent = TradingFeePolicy.netLeveragedReturnPercent(
                grossLeveragedReturnPercent: grossReturnPercent,
                leverage: leverage
            )

            let trade = BacktestTrade(
                symbol: signal.symbol,
                side: signal.side,
                entryTime: signal.generatedAt,
                exitTime: candle.openTime,
                entryPrice: signal.entryPrice,
                stopLoss: signal.stopLoss,
                takeProfit: signal.takeProfit,
                exitPrice: exitPrice,
                outcome: outcome,
                rewardRiskRatio: signal.plannedRewardRiskRatio ?? 0,
                leveragedReturnPercent: returnPercent,
                leveragedStopLossPercent: signal.leveragedStopLossPercent(leverage: leverage) ?? 0,
                reason: signal.reason
            )
            return (trade, index)
        }

        return nil
    }

    private func leveragedReturnPercent(
        side: TradeSide,
        entryPrice: Decimal,
        exitPrice: Decimal,
        leverage: Int
    ) -> Decimal {
        guard entryPrice > 0 else { return 0 }
        let move: Decimal
        switch side {
        case .buy:
            move = (exitPrice - entryPrice) / entryPrice
        case .sell:
            move = (entryPrice - exitPrice) / entryPrice
        }
        return move * 100 * Decimal(leverage)
    }
}

private extension Array where Element == BacktestTrade {
    var netReturnPercent: Decimal {
        reduce(0) { $0 + $1.leveragedReturnPercent }
    }

    var maxDrawdownPercent: Decimal {
        var equity: Decimal = 0
        var peak: Decimal = 0
        var maxDrawdown: Decimal = 0

        for trade in self {
            equity += trade.leveragedReturnPercent
            peak = Swift.max(peak, equity)
            maxDrawdown = Swift.max(maxDrawdown, peak - equity)
        }

        return maxDrawdown
    }

    var averageRewardRiskRatio: Decimal {
        guard isEmpty == false else { return 0 }
        return reduce(Decimal(0)) { $0 + $1.rewardRiskRatio } / Decimal(count)
    }

    var profitFactor: Decimal {
        let wins = filter { $0.leveragedReturnPercent > 0 }
            .reduce(Decimal(0)) { $0 + $1.leveragedReturnPercent }
        let losses = filter { $0.leveragedReturnPercent < 0 }
            .reduce(Decimal(0)) { $0 + absoluteDecimal($1.leveragedReturnPercent) }
        guard losses > 0 else { return wins > 0 ? 999 : 0 }
        return wins / losses
    }
}
