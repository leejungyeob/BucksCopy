import Foundation

struct BlockedCandleShortStrategy: TradingStrategy {
    static let identifier = "blocked-candle-short"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "막힘봉 숏",
        summary: "세 양봉 몸통 축소와 낮아진 고점 뒤 강한 음봉 확인으로 숏 진입",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [:]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        let candles = context.closedCandles
        guard candles.count >= 4 else { return .noSignal }

        let firstBull = candles[candles.count - 4]
        let secondBull = candles[candles.count - 3]
        let thirdBull = candles[candles.count - 2]
        let reversal = candles[candles.count - 1]

        guard firstBull.isBullish,
              secondBull.isBullish,
              thirdBull.isBullish,
              reversal.isBearish else {
            return .noSignal
        }

        guard firstBull.bodySize > secondBull.bodySize,
              secondBull.bodySize > thirdBull.bodySize,
              thirdBull.high < secondBull.high else {
            return .noSignal
        }

        guard reversal.closeLocation <= Decimal(4) / Decimal(10) else {
            return .noSignal
        }

        let entry = reversal.close
        let stop = reversal.high
        guard let takeProfit = takeProfit(
            context: context,
            firstBull: firstBull,
            entry: entry,
            stop: stop
        ) else {
            return .noSignal
        }

        return fixedTargetSignal(
            context: context,
            side: .sell,
            entry: entry,
            stop: stop,
            takeProfit: takeProfit,
            reason: "세 양봉의 몸통이 순차 축소되고 세 번째 고점이 낮아진 뒤 저가권 음봉으로 마감"
        )
    }

    private func takeProfit(
        context: StrategyContext,
        firstBull: Candle,
        entry: Decimal,
        stop: Decimal
    ) -> Decimal? {
        guard entry > 0, stop > entry else { return nil }

        switch context.timeframe {
        case .oneHour:
            return firstBull.open
        case .fifteenMinutes, .fourHours, .oneDay:
            let risk = stop - entry
            return entry - risk * StrategyRiskPolicy.minimumRewardRiskRatio
        case .twelveHours:
            return nil
        }
    }
}

private extension TradingStrategy {
    func fixedTargetSignal(
        context: StrategyContext,
        side: TradeSide,
        entry: Decimal,
        stop: Decimal,
        takeProfit: Decimal,
        reason: String
    ) -> StrategyEvaluation {
        let draft = StrategySignalDraft(
            strategyID: definition.id,
            symbol: context.symbol,
            side: side,
            entryPrice: entry,
            stopLoss: stop,
            takeProfit: takeProfit,
            reason: reason,
            generatedAt: context.generatedAt
        )

        guard let signal = try? draft.validated(), signal.hasValidPriceLayout else {
            return .noSignal
        }
        return .signal(signal)
    }
}

private extension Candle {
    var isBullish: Bool {
        close > open
    }

    var isBearish: Bool {
        close < open
    }

    var bodySize: Decimal {
        absoluteDecimal(close - open)
    }

    var closeLocation: Decimal {
        let range = high - low
        guard range > 0 else { return 1 }
        return (close - low) / range
    }
}
