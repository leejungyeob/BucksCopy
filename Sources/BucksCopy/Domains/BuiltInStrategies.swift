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

struct BlockedCandleLongStrategy: TradingStrategy {
    static let identifier = "blocked-candle-long"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "막힘봉 롱",
        summary: "세 음봉 몸통 축소와 높아진 저점 뒤 강한 양봉 확인으로 롱 진입",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [:]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        let candles = context.closedCandles
        guard candles.count >= 4 else { return .noSignal }

        let firstBear = candles[candles.count - 4]
        let secondBear = candles[candles.count - 3]
        let thirdBear = candles[candles.count - 2]
        let reversal = candles[candles.count - 1]

        guard firstBear.isBearish,
              secondBear.isBearish,
              thirdBear.isBearish,
              reversal.isBullish else {
            return .noSignal
        }

        guard firstBear.bodySize > secondBear.bodySize,
              secondBear.bodySize > thirdBear.bodySize,
              thirdBear.low > secondBear.low else {
            return .noSignal
        }

        guard reversal.closeLocation >= Decimal(6) / Decimal(10) else {
            return .noSignal
        }

        let entry = reversal.close
        let stop = reversal.low
        guard let takeProfit = takeProfit(
            context: context,
            firstBear: firstBear,
            entry: entry,
            stop: stop
        ) else {
            return .noSignal
        }

        return fixedTargetSignal(
            context: context,
            side: .buy,
            entry: entry,
            stop: stop,
            takeProfit: takeProfit,
            reason: "세 음봉의 몸통이 순차 축소되고 세 번째 저점이 높아진 뒤 고가권 양봉으로 마감"
        )
    }

    private func takeProfit(
        context: StrategyContext,
        firstBear: Candle,
        entry: Decimal,
        stop: Decimal
    ) -> Decimal? {
        guard entry > 0, stop < entry else { return nil }

        switch context.timeframe {
        case .oneHour:
            return firstBear.open
        case .fifteenMinutes, .fourHours, .oneDay:
            let risk = entry - stop
            return entry + risk * StrategyRiskPolicy.minimumRewardRiskRatio
        case .twelveHours:
            return nil
        }
    }
}

struct VWMATouchTrendStrategy: TradingStrategy {
    static let identifier = "vwma-touch-trend"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "VWMA100 터치 추세",
        summary: "VWMA100 아래에서 근접 반등 시 숏, 위에서 근접 지지 시 롱",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [:]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        let candles = context.closedCandles
        let parameters = VWMAParameters.optimized(for: context.timeframe, overrides: config.parameters)
        guard candles.count >= parameters.period,
              let vwma = candles.volumeWeightedMovingAverage(period: parameters.period) else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let entry = latest.close
        guard entry > 0 else { return .noSignal }

        if entry < vwma, latest.high >= vwma * (1 - parameters.nearPercent) {
            let stop = Swift.max(latest.high, vwma * (1 + parameters.stopBufferPercent))
            let risk = stop - entry
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "종가가 VWMA100 아래에 있고 고가가 VWMA100 근처까지 되돌림"
            )
        }

        if entry > vwma, latest.low <= vwma * (1 + parameters.nearPercent) {
            let stop = Swift.min(latest.low, vwma * (1 - parameters.stopBufferPercent))
            let risk = entry - stop
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "종가가 VWMA100 위에 있고 저가가 VWMA100 근처까지 되돌림"
            )
        }

        return .noSignal
    }
}

struct MovingAverageAlignmentStrategy: TradingStrategy {
    static let identifier = "moving-average-alignment"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "이평선 정역배열",
        summary: "MA25/50/100/200 정배열 전환은 롱, 역배열 전환은 숏",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [:]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        let candles = context.closedCandles
        guard candles.count >= 201 else { return .noSignal }

        let currentAlignment = movingAverageAlignment(candles: candles, endingAt: candles.count - 1)
        let previousAlignment = movingAverageAlignment(candles: candles, endingAt: candles.count - 2)
        guard let currentAlignment, currentAlignment != previousAlignment else {
            return .noSignal
        }

        let parameters = MovingAverageAlignmentParameters.optimized(
            for: context.timeframe,
            overrides: config.parameters
        )
        let latest = candles[candles.count - 1]
        let entry = latest.close
        guard entry > 0 else { return .noSignal }

        switch currentAlignment {
        case .bullish:
            guard let stop = stopLoss(
                side: .buy,
                entry: entry,
                candles: candles,
                parameters: parameters
            ) else { return .noSignal }
            let risk = entry - stop
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "MA25 > MA50 > MA100 > MA200 정배열 전환"
            )
        case .bearish:
            guard let stop = stopLoss(
                side: .sell,
                entry: entry,
                candles: candles,
                parameters: parameters
            ) else { return .noSignal }
            let risk = stop - entry
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "MA25 < MA50 < MA100 < MA200 역배열 전환"
            )
        }
    }

    private func movingAverageAlignment(candles: [Candle], endingAt index: Int) -> MovingAverageAlignment? {
        guard let ma25 = candles.simpleMovingAverage(period: 25, endingAt: index),
              let ma50 = candles.simpleMovingAverage(period: 50, endingAt: index),
              let ma100 = candles.simpleMovingAverage(period: 100, endingAt: index),
              let ma200 = candles.simpleMovingAverage(period: 200, endingAt: index) else {
            return nil
        }

        if ma25 > ma50, ma50 > ma100, ma100 > ma200 {
            return .bullish
        }
        if ma25 < ma50, ma50 < ma100, ma100 < ma200 {
            return .bearish
        }
        return nil
    }

    private func stopLoss(
        side: TradeSide,
        entry: Decimal,
        candles: [Candle],
        parameters: MovingAverageAlignmentParameters
    ) -> Decimal? {
        let percentStop: Decimal
        switch side {
        case .buy:
            percentStop = entry * (1 - parameters.stopPercent)
        case .sell:
            percentStop = entry * (1 + parameters.stopPercent)
        }

        guard let referenceStop = referenceStop(
            side: side,
            candles: candles,
            parameters: parameters
        ) else {
            return percentStop
        }

        switch side {
        case .buy:
            return Swift.min(percentStop, referenceStop)
        case .sell:
            return Swift.max(percentStop, referenceStop)
        }
    }

    private func referenceStop(
        side: TradeSide,
        candles: [Candle],
        parameters: MovingAverageAlignmentParameters
    ) -> Decimal? {
        switch parameters.stopMode {
        case .entryPercent:
            return nil
        case .movingAverage50:
            return candles.simpleMovingAverage(period: 50)
        case .movingAverage100:
            return candles.simpleMovingAverage(period: 100)
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

private enum MovingAverageAlignment {
    case bullish
    case bearish
}

private struct VWMAParameters {
    static let period = 100

    let period: Int
    let nearPercent: Decimal
    let stopBufferPercent: Decimal
    let rewardRiskRatio: Decimal

    static func optimized(for timeframe: CandleTimeframe, overrides: [String: Decimal]) -> VWMAParameters {
        let defaults: VWMAParameters
        switch timeframe {
        case .fifteenMinutes:
            defaults = VWMAParameters(period: period, nearPercent: Decimal(string: "0.012")!, stopBufferPercent: Decimal(string: "0.012")!, rewardRiskRatio: Decimal(string: "3.5")!)
        case .oneHour:
            defaults = VWMAParameters(period: period, nearPercent: Decimal(string: "0.008")!, stopBufferPercent: Decimal(string: "0.018")!, rewardRiskRatio: Decimal(string: "3.0")!)
        case .fourHours:
            defaults = VWMAParameters(period: period, nearPercent: Decimal(string: "0.012")!, stopBufferPercent: Decimal(string: "0.001")!, rewardRiskRatio: Decimal(string: "2.5")!)
        case .twelveHours:
            defaults = VWMAParameters(period: period, nearPercent: Decimal(string: "0.012")!, stopBufferPercent: Decimal(string: "0.005")!, rewardRiskRatio: Decimal(string: "4.0")!)
        case .oneDay:
            defaults = VWMAParameters(period: period, nearPercent: Decimal(string: "0.001")!, stopBufferPercent: Decimal(string: "0.005")!, rewardRiskRatio: Decimal(string: "2.5")!)
        }

        return VWMAParameters(
            period: Int(truncating: NSDecimalNumber(decimal: overrides["period"] ?? Decimal(Self.period))),
            nearPercent: overrides["nearPercent"] ?? defaults.nearPercent,
            stopBufferPercent: overrides["stopBufferPercent"] ?? defaults.stopBufferPercent,
            rewardRiskRatio: overrides["rewardRiskRatio"] ?? defaults.rewardRiskRatio
        )
    }
}

private struct MovingAverageAlignmentParameters {
    let stopPercent: Decimal
    let rewardRiskRatio: Decimal
    let stopMode: MovingAverageAlignmentStopMode

    static func optimized(
        for timeframe: CandleTimeframe,
        overrides: [String: Decimal]
    ) -> MovingAverageAlignmentParameters {
        let defaults: MovingAverageAlignmentParameters
        switch timeframe {
        case .fifteenMinutes:
            defaults = MovingAverageAlignmentParameters(stopPercent: Decimal(string: "0.025")!, rewardRiskRatio: Decimal(string: "4.0")!, stopMode: .movingAverage50)
        case .oneHour:
            defaults = MovingAverageAlignmentParameters(stopPercent: Decimal(string: "0.035")!, rewardRiskRatio: Decimal(string: "5.0")!, stopMode: .entryPercent)
        case .fourHours:
            defaults = MovingAverageAlignmentParameters(stopPercent: Decimal(string: "0.075")!, rewardRiskRatio: Decimal(string: "5.0")!, stopMode: .entryPercent)
        case .twelveHours:
            defaults = MovingAverageAlignmentParameters(stopPercent: Decimal(string: "0.035")!, rewardRiskRatio: Decimal(string: "2.0")!, stopMode: .entryPercent)
        case .oneDay:
            defaults = MovingAverageAlignmentParameters(stopPercent: Decimal(string: "0.075")!, rewardRiskRatio: Decimal(string: "5.0")!, stopMode: .entryPercent)
        }

        return MovingAverageAlignmentParameters(
            stopPercent: overrides["stopPercent"] ?? defaults.stopPercent,
            rewardRiskRatio: overrides["rewardRiskRatio"] ?? defaults.rewardRiskRatio,
            stopMode: defaults.stopMode
        )
    }
}

private enum MovingAverageAlignmentStopMode {
    case entryPercent
    case movingAverage50
    case movingAverage100
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

private extension Array where Element == Candle {
    func simpleMovingAverage(period: Int, endingAt index: Int? = nil) -> Decimal? {
        let endIndex = index ?? count - 1
        guard period > 0,
              endIndex >= 0,
              endIndex < count,
              endIndex - period + 1 >= 0 else {
            return nil
        }

        var sum: Decimal = 0
        for candle in self[(endIndex - period + 1)...endIndex] {
            sum += candle.close
        }
        return sum / Decimal(period)
    }

    func volumeWeightedMovingAverage(period: Int, endingAt index: Int? = nil) -> Decimal? {
        let endIndex = index ?? count - 1
        guard period > 0,
              endIndex >= 0,
              endIndex < count,
              endIndex - period + 1 >= 0 else {
            return nil
        }

        var weightedClose: Decimal = 0
        var volume: Decimal = 0
        for candle in self[(endIndex - period + 1)...endIndex] {
            weightedClose += candle.close * candle.volume
            volume += candle.volume
        }
        guard volume > 0 else { return nil }
        return weightedClose / volume
    }
}
