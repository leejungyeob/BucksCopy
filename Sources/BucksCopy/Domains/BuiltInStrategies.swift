import Foundation

struct XStrategy: TradingStrategy {
    static let identifier = "x"
    private static let supportedTimeframes: Set<CandleTimeframe> = [.fifteenMinutes]

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "X",
        summary: "24봉 누적 압력과 반대 꼬리 흡수, range/volume 확장을 조합한 15분봉 독자 전략",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                "pressureLookback": 24,
                "rangeLookback": 24,
                "volumeLookback": 96,
                "rangeMultiplier": Decimal(string: "1.7")!,
                "volumeMultiplier": Decimal(string: "1.4")!,
                "minimumCloseLocation": Decimal(string: "0.60")!,
                "minimumOppositeWickRatio": Decimal(string: "0.25")!,
                "minimumPressure": Decimal(string: "0.12")!,
                "rewardRiskRatio": Decimal(string: "2.4")!
            ],
            signalConfirmation: .disabled
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        guard Self.supportedTimeframes.contains(context.timeframe) else { return .noSignal }

        let candles = context.closedCandles
        let parameters = XParameters(overrides: config.parameters)
        guard candles.count > 220,
              let averageRange = candles.averageRange(
                period: parameters.rangeLookback,
                endingAt: candles.count - 2
              ),
              let averageVolume = candles.averageVolume(period: parameters.volumeLookback),
              let pressure = candles.directionalBodyPressure(
                lookback: parameters.pressureLookback,
                endingAt: candles.count - 2
              ) else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let entry = latest.close
        let range = latest.high - latest.low
        guard entry > 0,
              range > 0,
              averageRange > 0,
              averageVolume > 0,
              range >= averageRange * parameters.rangeMultiplier,
              latest.volume >= averageVolume * parameters.volumeMultiplier else {
            return .noSignal
        }

        let closeLocation = (latest.close - latest.low) / range
        let upperWickRatio = (latest.high - Swift.max(latest.open, latest.close)) / range
        let lowerWickRatio = (Swift.min(latest.open, latest.close) - latest.low) / range

        if pressure <= -parameters.minimumPressure,
           lowerWickRatio >= parameters.minimumOppositeWickRatio,
           closeLocation >= parameters.minimumCloseLocation,
           latest.close >= latest.open {
            let stop = latest.low
            let risk = entry - stop
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "X: 24봉 매도 압력 뒤 하단 꼬리 흡수와 range/volume 확장 확인"
            )
        }

        if pressure >= parameters.minimumPressure,
           upperWickRatio >= parameters.minimumOppositeWickRatio,
           closeLocation <= 1 - parameters.minimumCloseLocation,
           latest.close <= latest.open {
            let stop = latest.high
            let risk = stop - entry
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "X: 24봉 매수 압력 뒤 상단 꼬리 흡수와 range/volume 확장 확인"
            )
        }

        return .noSignal
    }
}

struct VWMATouchTrendStrategy: TradingStrategy {
    static let identifier = "vwma-touch-trend"
    private static let supportedTimeframes: Set<CandleTimeframe> = [.twelveHours, .oneDay]

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
        guard Self.supportedTimeframes.contains(context.timeframe) else { return .noSignal }
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

struct DonchianChannelBreakoutStrategy: TradingStrategy {
    static let identifier = "donchian-channel-breakout"
    private static let supportedTimeframes: Set<CandleTimeframe> = [.fourHours, .twelveHours, .oneDay]

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "Donchian 채널 돌파",
        summary: "최근 N봉 고점/저점 종가 돌파를 ATR 버퍼로 확인해 추세 진입",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [:]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        guard Self.supportedTimeframes.contains(context.timeframe) else { return .noSignal }
        let parameters = DonchianBreakoutParameters.optimized(
            for: context.timeframe,
            overrides: config.parameters
        )
        let candles = context.closedCandles
        guard candles.count > parameters.lookback + parameters.atrPeriod,
              let atr = candles.averageTrueRange(period: parameters.atrPeriod) else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let previous = candles[candles.count - 2]
        let previousHigh = candles.highestHigh(
            lookback: parameters.lookback,
            endingAt: candles.count - 2
        )
        let previousLow = candles.lowestLow(
            lookback: parameters.lookback,
            endingAt: candles.count - 2
        )
        guard let previousHigh, let previousLow, latest.close > 0 else { return .noSignal }

        let buffer = atr * parameters.breakoutBufferATR
        if previous.close <= previousHigh + buffer,
           latest.close > previousHigh + buffer {
            let entry = latest.close
            let stop = entry - atr * parameters.stopATR
            let risk = entry - stop
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "Donchian \(parameters.lookback)봉 상단을 ATR 버퍼와 함께 종가 돌파"
            )
        }

        if previous.close >= previousLow - buffer,
           latest.close < previousLow - buffer {
            let entry = latest.close
            let stop = entry + atr * parameters.stopATR
            let risk = stop - entry
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "Donchian \(parameters.lookback)봉 하단을 ATR 버퍼와 함께 종가 이탈"
            )
        }

        return .noSignal
    }
}

struct TimeSeriesMomentumStrategy: TradingStrategy {
    static let identifier = "time-series-momentum"
    private static let supportedTimeframes: Set<CandleTimeframe> = [.twelveHours]

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "Time-Series 모멘텀",
        summary: "최근 N봉 수익률이 임계값을 돌파하면 같은 방향 추세 추종",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [:]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        guard Self.supportedTimeframes.contains(context.timeframe) else { return .noSignal }
        let parameters = TimeSeriesMomentumParameters.optimized(
            for: context.timeframe,
            overrides: config.parameters
        )
        let candles = context.closedCandles
        guard candles.count > parameters.lookback + parameters.atrPeriod + 1,
              let atr = candles.averageTrueRange(period: parameters.atrPeriod) else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let currentBase = candles[candles.count - 1 - parameters.lookback]
        let previous = candles[candles.count - 2]
        let previousBase = candles[candles.count - 2 - parameters.lookback]
        guard latest.close > 0, currentBase.close > 0, previousBase.close > 0 else {
            return .noSignal
        }

        let currentReturn = (latest.close - currentBase.close) / currentBase.close
        let previousReturn = (previous.close - previousBase.close) / previousBase.close
        if previousReturn <= parameters.threshold,
           currentReturn > parameters.threshold {
            let entry = latest.close
            let stop = entry - atr * parameters.stopATR
            let risk = entry - stop
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "\(parameters.lookback)봉 수익률이 +\(parameters.threshold.riskText)% 임계값을 상향 돌파"
            )
        }

        if previousReturn >= -parameters.threshold,
           currentReturn < -parameters.threshold {
            let entry = latest.close
            let stop = entry + atr * parameters.stopATR
            let risk = stop - entry
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "\(parameters.lookback)봉 수익률이 -\(parameters.threshold.riskText)% 임계값을 하향 이탈"
            )
        }

        return .noSignal
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
            period: intOverride("period", overrides: overrides, defaultValue: Self.period),
            nearPercent: overrides["nearPercent"] ?? defaults.nearPercent,
            stopBufferPercent: overrides["stopBufferPercent"] ?? defaults.stopBufferPercent,
            rewardRiskRatio: overrides["rewardRiskRatio"] ?? defaults.rewardRiskRatio
        )
    }
}

private struct XParameters {
    let pressureLookback: Int
    let rangeLookback: Int
    let volumeLookback: Int
    let rangeMultiplier: Decimal
    let volumeMultiplier: Decimal
    let minimumCloseLocation: Decimal
    let minimumOppositeWickRatio: Decimal
    let minimumPressure: Decimal
    let rewardRiskRatio: Decimal

    init(overrides: [String: Decimal]) {
        pressureLookback = intOverride("pressureLookback", overrides: overrides, defaultValue: 24)
        rangeLookback = intOverride("rangeLookback", overrides: overrides, defaultValue: 24)
        volumeLookback = intOverride("volumeLookback", overrides: overrides, defaultValue: 96)
        rangeMultiplier = overrides["rangeMultiplier"] ?? Decimal(string: "1.7")!
        volumeMultiplier = overrides["volumeMultiplier"] ?? Decimal(string: "1.4")!
        minimumCloseLocation = overrides["minimumCloseLocation"] ?? Decimal(string: "0.60")!
        minimumOppositeWickRatio = overrides["minimumOppositeWickRatio"] ?? Decimal(string: "0.25")!
        minimumPressure = overrides["minimumPressure"] ?? Decimal(string: "0.12")!
        rewardRiskRatio = overrides["rewardRiskRatio"] ?? Decimal(string: "2.4")!
    }
}

private struct DonchianBreakoutParameters {
    let lookback: Int
    let atrPeriod: Int
    let breakoutBufferATR: Decimal
    let stopATR: Decimal
    let rewardRiskRatio: Decimal

    static func optimized(
        for timeframe: CandleTimeframe,
        overrides: [String: Decimal]
    ) -> DonchianBreakoutParameters {
        let defaults: DonchianBreakoutParameters
        switch timeframe {
        case .fifteenMinutes:
            defaults = DonchianBreakoutParameters(lookback: 40, atrPeriod: 14, breakoutBufferATR: Decimal(string: "0.15")!, stopATR: Decimal(string: "1.8")!, rewardRiskRatio: Decimal(string: "2.5")!)
        case .oneHour:
            defaults = DonchianBreakoutParameters(lookback: 24, atrPeriod: 14, breakoutBufferATR: Decimal(string: "0.20")!, stopATR: Decimal(string: "1.8")!, rewardRiskRatio: Decimal(string: "2.8")!)
        case .fourHours:
            defaults = DonchianBreakoutParameters(lookback: 20, atrPeriod: 14, breakoutBufferATR: Decimal(string: "0.20")!, stopATR: Decimal(string: "2.0")!, rewardRiskRatio: Decimal(string: "3.0")!)
        case .twelveHours:
            defaults = DonchianBreakoutParameters(lookback: 20, atrPeriod: 14, breakoutBufferATR: Decimal(string: "0.15")!, stopATR: Decimal(string: "2.0")!, rewardRiskRatio: Decimal(string: "3.2")!)
        case .oneDay:
            defaults = DonchianBreakoutParameters(lookback: 20, atrPeriod: 14, breakoutBufferATR: Decimal(string: "0.10")!, stopATR: Decimal(string: "2.0")!, rewardRiskRatio: Decimal(string: "3.0")!)
        }

        return DonchianBreakoutParameters(
            lookback: intOverride("lookback", overrides: overrides, defaultValue: defaults.lookback),
            atrPeriod: intOverride("atrPeriod", overrides: overrides, defaultValue: defaults.atrPeriod),
            breakoutBufferATR: overrides["breakoutBufferATR"] ?? defaults.breakoutBufferATR,
            stopATR: overrides["stopATR"] ?? defaults.stopATR,
            rewardRiskRatio: overrides["rewardRiskRatio"] ?? defaults.rewardRiskRatio
        )
    }
}

private struct TimeSeriesMomentumParameters {
    let lookback: Int
    let threshold: Decimal
    let atrPeriod: Int
    let stopATR: Decimal
    let rewardRiskRatio: Decimal

    static func optimized(
        for timeframe: CandleTimeframe,
        overrides: [String: Decimal]
    ) -> TimeSeriesMomentumParameters {
        let defaults: TimeSeriesMomentumParameters
        switch timeframe {
        case .fifteenMinutes:
            defaults = TimeSeriesMomentumParameters(lookback: 96, threshold: Decimal(string: "0.025")!, atrPeriod: 14, stopATR: Decimal(string: "2.0")!, rewardRiskRatio: Decimal(string: "2.5")!)
        case .oneHour:
            defaults = TimeSeriesMomentumParameters(lookback: 48, threshold: Decimal(string: "0.035")!, atrPeriod: 14, stopATR: Decimal(string: "2.0")!, rewardRiskRatio: Decimal(string: "2.8")!)
        case .fourHours:
            defaults = TimeSeriesMomentumParameters(lookback: 30, threshold: Decimal(string: "0.06")!, atrPeriod: 14, stopATR: Decimal(string: "2.2")!, rewardRiskRatio: Decimal(string: "3.0")!)
        case .twelveHours:
            defaults = TimeSeriesMomentumParameters(lookback: 20, threshold: Decimal(string: "0.08")!, atrPeriod: 14, stopATR: Decimal(string: "2.2")!, rewardRiskRatio: Decimal(string: "3.0")!)
        case .oneDay:
            defaults = TimeSeriesMomentumParameters(lookback: 20, threshold: Decimal(string: "0.10")!, atrPeriod: 14, stopATR: Decimal(string: "2.5")!, rewardRiskRatio: Decimal(string: "3.0")!)
        }

        return TimeSeriesMomentumParameters(
            lookback: intOverride("lookback", overrides: overrides, defaultValue: defaults.lookback),
            threshold: overrides["threshold"] ?? defaults.threshold,
            atrPeriod: intOverride("atrPeriod", overrides: overrides, defaultValue: defaults.atrPeriod),
            stopATR: overrides["stopATR"] ?? defaults.stopATR,
            rewardRiskRatio: overrides["rewardRiskRatio"] ?? defaults.rewardRiskRatio
        )
    }
}

private func intOverride(
    _ key: String,
    overrides: [String: Decimal],
    defaultValue: Int
) -> Int {
    guard let value = overrides[key] else { return defaultValue }
    return max(1, Int(truncating: NSDecimalNumber(decimal: value)))
}

private extension Array where Element == Candle {
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

    func averageVolume(period: Int, endingAt index: Int? = nil) -> Decimal? {
        let endIndex = index ?? count - 1
        guard period > 0,
              endIndex >= 0,
              endIndex < count,
              endIndex - period + 1 >= 0 else {
            return nil
        }

        var total: Decimal = 0
        for candle in self[(endIndex - period + 1)...endIndex] {
            total += candle.volume
        }
        return total / Decimal(period)
    }

    func averageRange(period: Int, endingAt index: Int? = nil) -> Decimal? {
        let endIndex = index ?? count - 1
        guard period > 0,
              endIndex >= 0,
              endIndex < count,
              endIndex - period + 1 >= 0 else {
            return nil
        }

        var total: Decimal = 0
        for candle in self[(endIndex - period + 1)...endIndex] {
            total += candle.high - candle.low
        }
        return total / Decimal(period)
    }

    func directionalBodyPressure(lookback: Int, endingAt index: Int) -> Decimal? {
        guard lookback > 0,
              index >= 0,
              index < count,
              index - lookback + 1 >= 0 else {
            return nil
        }

        var bodyTotal: Decimal = 0
        var rangeTotal: Decimal = 0
        for candle in self[(index - lookback + 1)...index] {
            bodyTotal += candle.close - candle.open
            rangeTotal += candle.high - candle.low
        }
        guard rangeTotal > 0 else { return nil }
        return bodyTotal / rangeTotal
    }

    func highestHigh(lookback: Int, endingAt index: Int) -> Decimal? {
        guard lookback > 0,
              index >= 0,
              index < count,
              index - lookback + 1 >= 0 else {
            return nil
        }
        return self[(index - lookback + 1)...index].map(\.high).max()
    }

    func lowestLow(lookback: Int, endingAt index: Int) -> Decimal? {
        guard lookback > 0,
              index >= 0,
              index < count,
              index - lookback + 1 >= 0 else {
            return nil
        }
        return self[(index - lookback + 1)...index].map(\.low).min()
    }

    func averageTrueRange(period: Int, endingAt index: Int? = nil) -> Decimal? {
        let endIndex = index ?? count - 1
        guard period > 0,
              endIndex > 0,
              endIndex < count,
              endIndex - period + 1 > 0 else {
            return nil
        }

        var total: Decimal = 0
        for candleIndex in (endIndex - period + 1)...endIndex {
            let candle = self[candleIndex]
            let previousClose = self[candleIndex - 1].close
            total += Swift.max(
                candle.high - candle.low,
                absoluteDecimal(candle.high - previousClose),
                absoluteDecimal(candle.low - previousClose)
            )
        }
        return total / Decimal(period)
    }
}
