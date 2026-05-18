import Foundation

struct XStrategy: TradingStrategy {
    static let identifier = "x"
    private static let supportedTimeframes: Set<CandleTimeframe> = [.fifteenMinutes]

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "X",
        summary: "SMA96/SMA384 phase spread와 ATR/volume gate로 압축 추세의 15분봉 reclaim만 진입하는 독자 전략",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                "fastMeanPeriod": 96,
                "slowMeanPeriod": 384,
                "atrPeriod": 14,
                "volumeLookback": 96,
                "minimumTrendSpread": Decimal(string: "0.004")!,
                "maximumTrendSpread": Decimal(string: "0.006")!,
                "minimumATRPercent": Decimal(string: "0.001")!,
                "maximumATRPercent": Decimal(string: "0.007")!,
                "minimumCloseLocation": Decimal(string: "0.80")!,
                "volumeMultiplier": Decimal(string: "1.5")!,
                "stopATRBuffer": Decimal(string: "0.15")!,
                "rewardRiskRatio": Decimal(string: "2.0")!
            ],
            signalConfirmation: .disabled
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        guard Self.supportedTimeframes.contains(context.timeframe) else { return .noSignal }

        let candles = context.closedCandles
        let parameters = XParameters(overrides: config.parameters)
        guard candles.count >= parameters.slowMeanPeriod,
              let fastMean = candles.simpleMovingAverage(period: parameters.fastMeanPeriod),
              let slowMean = candles.simpleMovingAverage(period: parameters.slowMeanPeriod),
              let atr = candles.averageTrueRange(period: parameters.atrPeriod),
              let averageVolume = candles.averageVolume(period: parameters.volumeLookback),
              candles.count >= 2 else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let previous = candles[candles.count - 2]
        let entry = latest.close
        let range = latest.high - latest.low
        guard entry > 0,
              range > 0,
              atr > 0,
              averageVolume > 0,
              latest.volume >= averageVolume * parameters.volumeMultiplier else {
            return .noSignal
        }

        let trendSpread = absoluteDecimal(fastMean - slowMean) / entry
        let atrPercent = atr / entry
        guard trendSpread >= parameters.minimumTrendSpread,
              trendSpread <= parameters.maximumTrendSpread,
              atrPercent >= parameters.minimumATRPercent,
              atrPercent <= parameters.maximumATRPercent else {
            return .noSignal
        }

        let closeLocation = (latest.close - latest.low) / range

        if parameters.allowsLong,
           fastMean > slowMean,
           latest.low <= fastMean,
           latest.close > fastMean,
           latest.close > previous.high,
           latest.close > latest.open,
           closeLocation >= parameters.minimumCloseLocation {
            let stop = Swift.min(latest.low, fastMean - atr * parameters.stopATRBuffer)
            let risk = entry - stop
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "X: SMA96/SMA384 phase spread 압축 추세에서 SMA96 하단 터치 후 고가 reclaim"
            )
        }

        if parameters.allowsShort,
           fastMean < slowMean,
           latest.high >= fastMean,
           latest.close < fastMean,
           latest.close < previous.low,
           latest.close < latest.open,
           closeLocation <= 1 - parameters.minimumCloseLocation {
            let stop = Swift.max(latest.high, fastMean + atr * parameters.stopATRBuffer)
            let risk = stop - entry
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "X: SMA96/SMA384 phase spread 압축 추세에서 SMA96 상단 터치 후 저가 reclaim"
            )
        }

        return .noSignal
    }
}

struct XFrequencyStrategy: TradingStrategy {
    static let identifier = "x-frequency"
    private static let supportedTimeframes: Set<CandleTimeframe> = [.fifteenMinutes]

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "X-Frequency",
        summary: "X phase-spread reclaim을 연 50회 안팎으로 압축한 15분봉 중빈도 전략",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                "fastMeanPeriod": 96,
                "slowMeanPeriod": 384,
                "atrPeriod": 14,
                "volumeLookback": 96,
                "reclaimLookback": 3,
                "minimumTrendSpread": Decimal(string: "0.001")!,
                "maximumTrendSpread": Decimal(string: "0.020")!,
                "minimumATRPercent": Decimal(string: "0.001")!,
                "maximumATRPercent": Decimal(string: "0.007")!,
                "minimumCloseLocation": Decimal(string: "0.80")!,
                "volumeMultiplier": Decimal(string: "1.5")!,
                "stopATRBuffer": Decimal(string: "0.25")!,
                "rewardRiskRatio": Decimal(string: "2.0")!
            ],
            signalConfirmation: .disabled
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        guard Self.supportedTimeframes.contains(context.timeframe) else { return .noSignal }

        let candles = context.closedCandles
        let parameters = XFrequencyParameters(overrides: config.parameters)
        guard candles.count >= parameters.slowMeanPeriod,
              candles.count >= parameters.reclaimLookback + 1,
              let fastMean = candles.simpleMovingAverage(period: parameters.fastMeanPeriod),
              let slowMean = candles.simpleMovingAverage(period: parameters.slowMeanPeriod),
              let atr = candles.averageTrueRange(period: parameters.atrPeriod),
              let averageVolume = candles.averageVolume(period: parameters.volumeLookback),
              let previousHigh = candles.highestHigh(
                lookback: parameters.reclaimLookback,
                endingAt: candles.count - 2
              ),
              let previousLow = candles.lowestLow(
                lookback: parameters.reclaimLookback,
                endingAt: candles.count - 2
              ) else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let entry = latest.close
        let range = latest.high - latest.low
        guard entry > 0,
              range > 0,
              atr > 0,
              averageVolume > 0,
              latest.volume >= averageVolume * parameters.volumeMultiplier else {
            return .noSignal
        }

        let trendSpread = absoluteDecimal(fastMean - slowMean) / entry
        let atrPercent = atr / entry
        guard trendSpread >= parameters.minimumTrendSpread,
              trendSpread <= parameters.maximumTrendSpread,
              atrPercent >= parameters.minimumATRPercent,
              atrPercent <= parameters.maximumATRPercent else {
            return .noSignal
        }

        let closeLocation = (latest.close - latest.low) / range

        if parameters.allowsLong,
           fastMean > slowMean,
           latest.low <= fastMean,
           latest.close > fastMean,
           latest.close > previousHigh,
           latest.close > latest.open,
           closeLocation >= parameters.minimumCloseLocation {
            let stop = Swift.min(latest.low, fastMean - atr * parameters.stopATRBuffer)
            let risk = entry - stop
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "X-Frequency: SMA96/SMA384 phase spread 추세에서 3봉 고가 reclaim"
            )
        }

        if parameters.allowsShort,
           fastMean < slowMean,
           latest.high >= fastMean,
           latest.close < fastMean,
           latest.close < previousLow,
           latest.close < latest.open,
           closeLocation <= 1 - parameters.minimumCloseLocation {
            let stop = Swift.max(latest.high, fastMean + atr * parameters.stopATRBuffer)
            let risk = stop - entry
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "X-Frequency: SMA96/SMA384 phase spread 추세에서 3봉 저가 reclaim"
            )
        }

        return .noSignal
    }
}

struct BTCFifteenMinutePhaseVacuumReclaimStrategy: TradingStrategy {
    static let identifier = "btc-15m-phase-vacuum-reclaim"
    private static let supportedSymbol = FuturesSymbol("BTCUSDT")
    private static let supportedTimeframes: Set<CandleTimeframe> = [.fifteenMinutes]

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "BTC 15m Phase Vacuum Reclaim",
        summary: "BTCUSDT 15분봉 전용 SMA96/SMA384 phase reclaim 공격형 필터",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 10,
            parameters: [
                "fastMeanPeriod": 96,
                "slowMeanPeriod": 384,
                "atrPeriod": 14,
                "volumeLookback": 144,
                "reclaimLookback": 2,
                "minimumTrendSpread": Decimal(string: "0.002")!,
                "maximumTrendSpread": Decimal(string: "0.020")!,
                "minimumATRPercent": Decimal(string: "0.001")!,
                "maximumATRPercent": Decimal(string: "0.0075")!,
                "minimumCloseLocation": Decimal(string: "0.76")!,
                "volumeMultiplier": Decimal(string: "2.0")!,
                "stopATRBuffer": Decimal(string: "0.45")!,
                "rewardRiskRatio": Decimal(string: "3.5")!
            ],
            maximumRiskPerTradePercent: 15,
            maximumPositionMarginPercent: 100,
            signalConfirmation: .disabled
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        guard context.symbol == Self.supportedSymbol,
              Self.supportedTimeframes.contains(context.timeframe) else {
            return .noSignal
        }

        let candles = context.closedCandles
        let parameters = XFrequencyParameters(overrides: config.parameters)
        guard candles.count >= parameters.slowMeanPeriod,
              candles.count >= parameters.reclaimLookback + 1,
              let fastMean = candles.simpleMovingAverage(period: parameters.fastMeanPeriod),
              let slowMean = candles.simpleMovingAverage(period: parameters.slowMeanPeriod),
              let atr = candles.averageTrueRange(period: parameters.atrPeriod),
              let averageVolume = candles.averageVolume(period: parameters.volumeLookback),
              let previousHigh = candles.highestHigh(
                lookback: parameters.reclaimLookback,
                endingAt: candles.count - 2
              ),
              let previousLow = candles.lowestLow(
                lookback: parameters.reclaimLookback,
                endingAt: candles.count - 2
              ) else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let entry = latest.close
        let range = latest.high - latest.low
        guard entry > 0,
              range > 0,
              atr > 0,
              averageVolume > 0,
              latest.volume >= averageVolume * parameters.volumeMultiplier else {
            return .noSignal
        }

        let trendSpread = absoluteDecimal(fastMean - slowMean) / entry
        let atrPercent = atr / entry
        guard trendSpread >= parameters.minimumTrendSpread,
              trendSpread <= parameters.maximumTrendSpread,
              atrPercent >= parameters.minimumATRPercent,
              atrPercent <= parameters.maximumATRPercent else {
            return .noSignal
        }

        let closeLocation = (latest.close - latest.low) / range

        if parameters.allowsLong,
           fastMean > slowMean,
           latest.low <= fastMean,
           latest.close > fastMean,
           latest.close > previousHigh,
           latest.close > latest.open,
           closeLocation >= parameters.minimumCloseLocation {
            let stop = Swift.min(latest.low, fastMean - atr * parameters.stopATRBuffer)
            let risk = entry - stop
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "BTC 15m Phase Vacuum Reclaim: SMA96/SMA384 phase에서 2봉 고가 reclaim"
            )
        }

        if parameters.allowsShort,
           fastMean < slowMean,
           latest.high >= fastMean,
           latest.close < fastMean,
           latest.close < previousLow,
           latest.close < latest.open,
           closeLocation <= 1 - parameters.minimumCloseLocation {
            let stop = Swift.max(latest.high, fastMean + atr * parameters.stopATRBuffer)
            let risk = stop - entry
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "BTC 15m Phase Vacuum Reclaim: SMA96/SMA384 phase에서 2봉 저가 reclaim"
            )
        }

        return .noSignal
    }
}

struct XOneHourLongStrategy: TradingStrategy {
    static let identifier = "x-1h-long"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "X 1H Long",
        summary: "1시간봉 SMA24/SMA96 phase spread에서 눌림 후 고가 reclaim만 매수하는 X 계열 전략",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                "fastMeanPeriod": 24,
                "slowMeanPeriod": 96,
                "atrPeriod": 14,
                "volumeLookback": 48,
                "minimumTrendSpread": Decimal(string: "0.002")!,
                "maximumTrendSpread": Decimal(string: "0.025")!,
                "minimumATRPercent": Decimal(string: "0.0015")!,
                "maximumATRPercent": Decimal(string: "0.012")!,
                "minimumCloseLocation": Decimal(string: "0.72")!,
                "volumeMultiplier": Decimal(string: "1.2")!,
                "stopATRBuffer": Decimal(string: "0.30")!,
                "rewardRiskRatio": Decimal(string: "2.2")!
            ],
            signalConfirmation: .disabled
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        XOneHourReclaimEvaluator.evaluate(
            context,
            config: config,
            definition: definition,
            side: .buy
        )
    }
}

struct XOneHourShortStrategy: TradingStrategy {
    static let identifier = "x-1h-short"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "X 1H Short",
        summary: "1시간봉 SMA24/SMA96 phase spread에서 되돌림 후 저가 reclaim만 매도하는 X 계열 전략",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                "fastMeanPeriod": 24,
                "slowMeanPeriod": 96,
                "atrPeriod": 14,
                "volumeLookback": 48,
                "minimumTrendSpread": Decimal(string: "0.002")!,
                "maximumTrendSpread": Decimal(string: "0.025")!,
                "minimumATRPercent": Decimal(string: "0.0015")!,
                "maximumATRPercent": Decimal(string: "0.012")!,
                "minimumCloseLocation": Decimal(string: "0.72")!,
                "volumeMultiplier": Decimal(string: "1.2")!,
                "stopATRBuffer": Decimal(string: "0.30")!,
                "rewardRiskRatio": Decimal(string: "2.2")!
            ],
            signalConfirmation: .disabled
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        XOneHourReclaimEvaluator.evaluate(
            context,
            config: config,
            definition: definition,
            side: .sell
        )
    }
}

struct ETHFifteenMinuteReclaimStrategy: TradingStrategy {
    static let identifier = "eth-15m-reclaim"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "ETH 15m Reclaim",
        summary: "ETH 15분봉 SMA48/SMA192 추세 눌림 이후 단기 고저점 reclaim만 진입하는 전용 전략",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                "fastMeanPeriod": 48,
                "slowMeanPeriod": 192,
                "slowSlopeLookback": 24,
                "atrPeriod": 14,
                "volumeLookback": 64,
                "reclaimLookback": 4,
                "stopLookback": 8,
                "pressureLookback": 12,
                "minimumTrendSpread": Decimal(string: "0.0015")!,
                "maximumTrendSpread": Decimal(string: "0.035")!,
                "minimumATRPercent": Decimal(string: "0.0015")!,
                "maximumATRPercent": Decimal(string: "0.012")!,
                "volumeMultiplier": Decimal(string: "1.05")!,
                "minimumCloseLocation": Decimal(string: "0.66")!,
                "minimumSlope": Decimal(string: "0.0008")!,
                "minimumPressure": Decimal(string: "0.02")!,
                "pullbackATRBuffer": Decimal(string: "0.20")!,
                "stopATRBuffer": Decimal(string: "0.15")!,
                "minimumStopPercent": Decimal(string: "0.001")!,
                "maximumStopPercent": Decimal(string: "0.0045")!,
                "rewardRiskRatio": Decimal(string: "2.1")!,
                "sideMode": 0
            ],
            signalConfirmation: .disabled
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        ETHFifteenMinuteReclaimEvaluator.evaluate(
            context,
            config: config,
            definition: definition
        )
    }
}

struct ETHFifteenMinuteCompressionBreakoutStrategy: TradingStrategy {
    static let identifier = "eth-15m-compression-breakout"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "ETH 15m Compression Breakout",
        summary: "ETH 15분봉 단기 range compression 이후 거래량 동반 Donchian 이탈만 추종하는 전용 전략",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                "trendFastPeriod": 64,
                "trendSlowPeriod": 256,
                "atrPeriod": 14,
                "shortRangePeriod": 12,
                "longRangePeriod": 96,
                "volumeLookback": 80,
                "breakoutLookback": 18,
                "maximumCompressionRatio": Decimal(string: "0.88")!,
                "minimumTrendSpread": Decimal(string: "0.001")!,
                "maximumTrendSpread": Decimal(string: "0.045")!,
                "minimumATRPercent": Decimal(string: "0.0012")!,
                "maximumATRPercent": Decimal(string: "0.012")!,
                "volumeMultiplier": Decimal(string: "1.15")!,
                "breakoutATRBuffer": Decimal(string: "0.05")!,
                "stopATR": Decimal(string: "1.15")!,
                "rewardRiskRatio": Decimal(string: "2.2")!,
                "sideMode": 0
            ],
            signalConfirmation: .disabled
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        ETHFifteenMinuteCompressionBreakoutEvaluator.evaluate(
            context,
            config: config,
            definition: definition
        )
    }
}

struct ETHFifteenMinuteVWMAReversionStrategy: TradingStrategy {
    static let identifier = "eth-15m-vwma-reversion"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "ETH 15m VWMA Reversion",
        summary: "ETH 15분봉 VWMA96/ATR 밴드 과확장 뒤 종가 회복만 역추세 진입하는 전용 전략",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                "vwmaPeriod": 96,
                "trendFastPeriod": 48,
                "trendSlowPeriod": 192,
                "atrPeriod": 14,
                "volumeLookback": 64,
                "maximumTrendSpread": Decimal(string: "0.018")!,
                "minimumATRPercent": Decimal(string: "0.0015")!,
                "maximumATRPercent": Decimal(string: "0.012")!,
                "volumeMultiplier": Decimal(string: "0.85")!,
                "bandATR": Decimal(string: "1.45")!,
                "stopATRBuffer": Decimal(string: "0.20")!,
                "minimumCloseLocation": Decimal(string: "0.68")!,
                "rewardRiskRatio": Decimal(string: "2.0")!,
                "sideMode": 0
            ],
            signalConfirmation: .disabled
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        ETHFifteenMinuteVWMAReversionEvaluator.evaluate(
            context,
            config: config,
            definition: definition
        )
    }
}

struct ETHFifteenMinuteMomentumBurstStrategy: TradingStrategy {
    static let identifier = "eth-15m-momentum-burst"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "ETH 15m Momentum Burst",
        summary: "ETH 15분봉 12시간 수익률 전환과 SMA96/SMA384 방향이 맞을 때만 진입하는 고빈도 모멘텀 전략",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                "lookback": 48,
                "threshold": Decimal(string: "0.025")!,
                "fastMeanPeriod": 96,
                "slowMeanPeriod": 384,
                "atrPeriod": 14,
                "volumeLookback": 96,
                "minimumATRPercent": Decimal(string: "0.0012")!,
                "maximumATRPercent": Decimal(string: "0.018")!,
                "volumeMultiplier": Decimal(string: "0.90")!,
                "stopATR": Decimal(string: "1.20")!,
                "minimumStopPercent": Decimal(string: "0.001")!,
                "maximumStopPercent": Decimal(string: "0.006")!,
                "rewardRiskRatio": Decimal(string: "2.5")!,
                "sideMode": 0
            ],
            signalConfirmation: .disabled
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        ETHFifteenMinuteMomentumBurstEvaluator.evaluate(
            context,
            config: config,
            definition: definition
        )
    }
}

struct ETHOneHourMomentumBurstStrategy: TradingStrategy {
    static let identifier = "eth-1h-momentum-burst"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "ETH 1H Momentum Burst",
        summary: "ETH 1시간봉 단기 수익률 전환과 SMA24/SMA96 방향이 맞을 때만 진입하는 중빈도 모멘텀 전략",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                "lookback": 12,
                "threshold": Decimal(string: "0.04")!,
                "fastMeanPeriod": 24,
                "slowMeanPeriod": 96,
                "slowSlopeLookback": 24,
                "atrPeriod": 14,
                "volumeLookback": 48,
                "pressureLookback": 12,
                "minimumATRPercent": Decimal(string: "0.002")!,
                "maximumATRPercent": Decimal(string: "0.025")!,
                "minimumSlope": 0,
                "minimumPressure": 0,
                "volumeMultiplier": Decimal(string: "0.95")!,
                "stopATR": Decimal(string: "1.20")!,
                "minimumStopPercent": Decimal(string: "0.0015")!,
                "maximumStopPercent": Decimal(string: "0.019")!,
                "rewardRiskRatio": Decimal(string: "2.5")!,
                "sideMode": 0
            ],
            signalConfirmation: .disabled
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        ETHOneHourMomentumBurstEvaluator.evaluate(
            context,
            config: config,
            definition: definition
        )
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

private enum ETHFifteenMinuteReclaimEvaluator {
    static func evaluate(
        _ context: StrategyContext,
        config: StrategyConfig,
        definition: StrategyDefinition
    ) -> StrategyEvaluation {
        guard context.symbol == FuturesSymbol("ETHUSDT"),
              context.timeframe == .fifteenMinutes else {
            return .noSignal
        }

        let candles = context.closedCandles
        let parameters = ETHFifteenMinuteReclaimParameters(overrides: config.parameters)
        guard candles.count >= parameters.slowMeanPeriod + parameters.slowSlopeLookback,
              candles.count >= parameters.reclaimLookback + 2,
              let fastMean = candles.simpleMovingAverage(period: parameters.fastMeanPeriod),
              let slowMean = candles.simpleMovingAverage(period: parameters.slowMeanPeriod),
              let priorSlowMean = candles.simpleMovingAverage(
                period: parameters.slowMeanPeriod,
                endingAt: candles.count - 1 - parameters.slowSlopeLookback
              ),
              let atr = candles.averageTrueRange(period: parameters.atrPeriod),
              let averageVolume = candles.averageVolume(period: parameters.volumeLookback),
              let previousHigh = candles.highestHigh(
                lookback: parameters.reclaimLookback,
                endingAt: candles.count - 2
              ),
              let previousLow = candles.lowestLow(
                lookback: parameters.reclaimLookback,
                endingAt: candles.count - 2
              ),
              let bodyPressure = candles.directionalBodyPressure(
                lookback: parameters.pressureLookback,
                endingAt: candles.count - 1
              ) else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let entry = latest.close
        let range = latest.high - latest.low
        guard entry > 0,
              range > 0,
              atr > 0,
              averageVolume > 0,
              priorSlowMean > 0,
              latest.volume >= averageVolume * parameters.volumeMultiplier else {
            return .noSignal
        }

        let trendSpread = absoluteDecimal(fastMean - slowMean) / entry
        let atrPercent = atr / entry
        let slowSlope = (slowMean - priorSlowMean) / priorSlowMean
        let closeLocation = (latest.close - latest.low) / range

        guard trendSpread >= parameters.minimumTrendSpread,
              trendSpread <= parameters.maximumTrendSpread,
              atrPercent >= parameters.minimumATRPercent,
              atrPercent <= parameters.maximumATRPercent else {
            return .noSignal
        }

        if parameters.allowsLong,
           fastMean > slowMean,
           slowSlope >= parameters.minimumSlope,
           latest.low <= fastMean + atr * parameters.pullbackATRBuffer,
           latest.close > fastMean,
           latest.close > previousHigh,
           latest.close > latest.open,
           closeLocation >= parameters.minimumCloseLocation,
           bodyPressure >= parameters.minimumPressure {
            let stop = fastMean - atr * parameters.stopATRBuffer
            let risk = entry - stop
            guard parameters.allowsRisk(risk, entry: entry) else { return .noSignal }
            return strategyFixedTargetSignal(
                definition: definition,
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "ETH 15m Reclaim: SMA48/SMA192 상승 추세 눌림 후 \(parameters.reclaimLookback)봉 고가 reclaim"
            )
        }

        if parameters.allowsShort,
           fastMean < slowMean,
           slowSlope <= -parameters.minimumSlope,
           latest.high >= fastMean - atr * parameters.pullbackATRBuffer,
           latest.close < fastMean,
           latest.close < previousLow,
           latest.close < latest.open,
           closeLocation <= 1 - parameters.minimumCloseLocation,
           bodyPressure <= -parameters.minimumPressure {
            let stop = fastMean + atr * parameters.stopATRBuffer
            let risk = stop - entry
            guard parameters.allowsRisk(risk, entry: entry) else { return .noSignal }
            return strategyFixedTargetSignal(
                definition: definition,
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "ETH 15m Reclaim: SMA48/SMA192 하락 추세 되돌림 후 \(parameters.reclaimLookback)봉 저가 reclaim"
            )
        }

        return .noSignal
    }
}

private enum ETHFifteenMinuteCompressionBreakoutEvaluator {
    static func evaluate(
        _ context: StrategyContext,
        config: StrategyConfig,
        definition: StrategyDefinition
    ) -> StrategyEvaluation {
        guard context.symbol == FuturesSymbol("ETHUSDT"),
              context.timeframe == .fifteenMinutes else {
            return .noSignal
        }

        let candles = context.closedCandles
        let parameters = ETHFifteenMinuteCompressionBreakoutParameters(overrides: config.parameters)
        guard candles.count >= parameters.trendSlowPeriod,
              candles.count >= parameters.longRangePeriod,
              candles.count >= parameters.breakoutLookback + 2,
              let fastMean = candles.simpleMovingAverage(period: parameters.trendFastPeriod),
              let slowMean = candles.simpleMovingAverage(period: parameters.trendSlowPeriod),
              let atr = candles.averageTrueRange(period: parameters.atrPeriod),
              let shortRange = candles.averageRange(period: parameters.shortRangePeriod),
              let longRange = candles.averageRange(period: parameters.longRangePeriod),
              let averageVolume = candles.averageVolume(period: parameters.volumeLookback),
              let previousHigh = candles.highestHigh(
                lookback: parameters.breakoutLookback,
                endingAt: candles.count - 2
              ),
              let previousLow = candles.lowestLow(
                lookback: parameters.breakoutLookback,
                endingAt: candles.count - 2
              ) else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let entry = latest.close
        guard entry > 0,
              atr > 0,
              longRange > 0,
              averageVolume > 0,
              latest.volume >= averageVolume * parameters.volumeMultiplier else {
            return .noSignal
        }

        let compressionRatio = shortRange / longRange
        let trendSpread = absoluteDecimal(fastMean - slowMean) / entry
        let atrPercent = atr / entry
        let buffer = atr * parameters.breakoutATRBuffer
        guard compressionRatio <= parameters.maximumCompressionRatio,
              trendSpread >= parameters.minimumTrendSpread,
              trendSpread <= parameters.maximumTrendSpread,
              atrPercent >= parameters.minimumATRPercent,
              atrPercent <= parameters.maximumATRPercent else {
            return .noSignal
        }

        if parameters.allowsLong,
           fastMean > slowMean,
           latest.close > previousHigh + buffer,
           latest.close > latest.open {
            let stop = entry - atr * parameters.stopATR
            let risk = entry - stop
            guard risk > 0 else { return .noSignal }
            return strategyFixedTargetSignal(
                definition: definition,
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "ETH 15m Compression Breakout: range compression 후 \(parameters.breakoutLookback)봉 상단 거래량 돌파"
            )
        }

        if parameters.allowsShort,
           fastMean < slowMean,
           latest.close < previousLow - buffer,
           latest.close < latest.open {
            let stop = entry + atr * parameters.stopATR
            let risk = stop - entry
            guard risk > 0 else { return .noSignal }
            return strategyFixedTargetSignal(
                definition: definition,
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "ETH 15m Compression Breakout: range compression 후 \(parameters.breakoutLookback)봉 하단 거래량 이탈"
            )
        }

        return .noSignal
    }
}

private enum ETHFifteenMinuteVWMAReversionEvaluator {
    static func evaluate(
        _ context: StrategyContext,
        config: StrategyConfig,
        definition: StrategyDefinition
    ) -> StrategyEvaluation {
        guard context.symbol == FuturesSymbol("ETHUSDT"),
              context.timeframe == .fifteenMinutes else {
            return .noSignal
        }

        let candles = context.closedCandles
        let parameters = ETHFifteenMinuteVWMAReversionParameters(overrides: config.parameters)
        guard candles.count >= parameters.trendSlowPeriod,
              let vwma = candles.volumeWeightedMovingAverage(period: parameters.vwmaPeriod),
              let fastMean = candles.simpleMovingAverage(period: parameters.trendFastPeriod),
              let slowMean = candles.simpleMovingAverage(period: parameters.trendSlowPeriod),
              let atr = candles.averageTrueRange(period: parameters.atrPeriod),
              let averageVolume = candles.averageVolume(period: parameters.volumeLookback) else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let entry = latest.close
        let range = latest.high - latest.low
        guard entry > 0,
              range > 0,
              atr > 0,
              averageVolume > 0,
              latest.volume >= averageVolume * parameters.volumeMultiplier else {
            return .noSignal
        }

        let trendSpread = absoluteDecimal(fastMean - slowMean) / entry
        let atrPercent = atr / entry
        let lowerBand = vwma - atr * parameters.bandATR
        let upperBand = vwma + atr * parameters.bandATR
        let closeLocation = (latest.close - latest.low) / range
        guard trendSpread <= parameters.maximumTrendSpread,
              atrPercent >= parameters.minimumATRPercent,
              atrPercent <= parameters.maximumATRPercent else {
            return .noSignal
        }

        if parameters.allowsLong,
           latest.low < lowerBand,
           latest.close > lowerBand,
           latest.close > latest.open,
           closeLocation >= parameters.minimumCloseLocation {
            let stop = latest.low - atr * parameters.stopATRBuffer
            let risk = entry - stop
            guard risk > 0 else { return .noSignal }
            return strategyFixedTargetSignal(
                definition: definition,
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "ETH 15m VWMA Reversion: VWMA96 하단 ATR 밴드 이탈 후 종가 회복"
            )
        }

        if parameters.allowsShort,
           latest.high > upperBand,
           latest.close < upperBand,
           latest.close < latest.open,
           closeLocation <= 1 - parameters.minimumCloseLocation {
            let stop = latest.high + atr * parameters.stopATRBuffer
            let risk = stop - entry
            guard risk > 0 else { return .noSignal }
            return strategyFixedTargetSignal(
                definition: definition,
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "ETH 15m VWMA Reversion: VWMA96 상단 ATR 밴드 이탈 후 종가 회복"
            )
        }

        return .noSignal
    }
}

private enum ETHOneHourMomentumBurstEvaluator {
    static func evaluate(
        _ context: StrategyContext,
        config: StrategyConfig,
        definition: StrategyDefinition
    ) -> StrategyEvaluation {
        guard context.symbol == FuturesSymbol("ETHUSDT"),
              context.timeframe == .oneHour else {
            return .noSignal
        }

        let candles = context.closedCandles
        let parameters = ETHOneHourMomentumBurstParameters(overrides: config.parameters)
        guard candles.count > parameters.lookback + parameters.atrPeriod + 1,
              candles.count >= parameters.slowMeanPeriod + parameters.slowSlopeLookback,
              let fastMean = candles.simpleMovingAverage(period: parameters.fastMeanPeriod),
              let slowMean = candles.simpleMovingAverage(period: parameters.slowMeanPeriod),
              let priorSlowMean = candles.simpleMovingAverage(
                period: parameters.slowMeanPeriod,
                endingAt: candles.count - 1 - parameters.slowSlopeLookback
              ),
              let atr = candles.averageTrueRange(period: parameters.atrPeriod),
              let averageVolume = candles.averageVolume(period: parameters.volumeLookback),
              let bodyPressure = candles.directionalBodyPressure(
                lookback: parameters.pressureLookback,
                endingAt: candles.count - 1
              ) else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let previous = candles[candles.count - 2]
        let currentBase = candles[candles.count - 1 - parameters.lookback]
        let previousBase = candles[candles.count - 2 - parameters.lookback]
        guard latest.close > 0,
              currentBase.close > 0,
              previousBase.close > 0,
              priorSlowMean > 0,
              atr > 0,
              averageVolume > 0,
              latest.volume >= averageVolume * parameters.volumeMultiplier else {
            return .noSignal
        }

        let currentReturn = (latest.close - currentBase.close) / currentBase.close
        let previousReturn = (previous.close - previousBase.close) / previousBase.close
        let slowSlope = (slowMean - priorSlowMean) / priorSlowMean
        let atrPercent = atr / latest.close
        guard atrPercent >= parameters.minimumATRPercent,
              atrPercent <= parameters.maximumATRPercent else {
            return .noSignal
        }

        if parameters.allowsLong,
           fastMean > slowMean,
           (parameters.minimumSlope <= 0 || slowSlope >= parameters.minimumSlope),
           previousReturn <= parameters.threshold,
           currentReturn > parameters.threshold,
           (parameters.minimumPressure <= 0 || bodyPressure >= parameters.minimumPressure),
           latest.close > latest.open {
            let entry = latest.close
            let stop = entry - atr * parameters.stopATR
            let risk = entry - stop
            guard parameters.allowsRisk(risk, entry: entry) else { return .noSignal }
            return strategyFixedTargetSignal(
                definition: definition,
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "ETH 1H Momentum Burst: \(parameters.lookback)시간 수익률이 +\(parameters.threshold.riskText)% 임계값을 추세 방향으로 상향 돌파"
            )
        }

        if parameters.allowsShort,
           fastMean < slowMean,
           (parameters.minimumSlope <= 0 || slowSlope <= -parameters.minimumSlope),
           previousReturn >= -parameters.threshold,
           currentReturn < -parameters.threshold,
           (parameters.minimumPressure <= 0 || bodyPressure <= -parameters.minimumPressure),
           latest.close < latest.open {
            let entry = latest.close
            let stop = entry + atr * parameters.stopATR
            let risk = stop - entry
            guard parameters.allowsRisk(risk, entry: entry) else { return .noSignal }
            return strategyFixedTargetSignal(
                definition: definition,
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "ETH 1H Momentum Burst: \(parameters.lookback)시간 수익률이 -\(parameters.threshold.riskText)% 임계값을 추세 방향으로 하향 이탈"
            )
        }

        return .noSignal
    }
}

private enum ETHFifteenMinuteMomentumBurstEvaluator {
    static func evaluate(
        _ context: StrategyContext,
        config: StrategyConfig,
        definition: StrategyDefinition
    ) -> StrategyEvaluation {
        guard context.symbol == FuturesSymbol("ETHUSDT"),
              context.timeframe == .fifteenMinutes else {
            return .noSignal
        }

        let candles = context.closedCandles
        let parameters = ETHFifteenMinuteMomentumBurstParameters(overrides: config.parameters)
        guard candles.count > parameters.lookback + parameters.atrPeriod + 1,
              candles.count >= parameters.slowMeanPeriod,
              let fastMean = candles.simpleMovingAverage(period: parameters.fastMeanPeriod),
              let slowMean = candles.simpleMovingAverage(period: parameters.slowMeanPeriod),
              let atr = candles.averageTrueRange(period: parameters.atrPeriod),
              let averageVolume = candles.averageVolume(period: parameters.volumeLookback) else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let previous = candles[candles.count - 2]
        let currentBase = candles[candles.count - 1 - parameters.lookback]
        let previousBase = candles[candles.count - 2 - parameters.lookback]
        guard latest.close > 0,
              currentBase.close > 0,
              previousBase.close > 0,
              atr > 0,
              averageVolume > 0,
              latest.volume >= averageVolume * parameters.volumeMultiplier else {
            return .noSignal
        }

        let currentReturn = (latest.close - currentBase.close) / currentBase.close
        let previousReturn = (previous.close - previousBase.close) / previousBase.close
        let atrPercent = atr / latest.close
        guard atrPercent >= parameters.minimumATRPercent,
              atrPercent <= parameters.maximumATRPercent else {
            return .noSignal
        }

        if parameters.allowsLong,
           fastMean > slowMean,
           previousReturn <= parameters.threshold,
           currentReturn > parameters.threshold,
           latest.close > latest.open {
            let entry = latest.close
            let stop = entry - atr * parameters.stopATR
            let risk = entry - stop
            guard parameters.allowsRisk(risk, entry: entry) else { return .noSignal }
            return strategyFixedTargetSignal(
                definition: definition,
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "ETH 15m Momentum Burst: \(parameters.lookback)봉 수익률이 +\(parameters.threshold.riskText)% 임계값을 추세 방향으로 상향 돌파"
            )
        }

        if parameters.allowsShort,
           fastMean < slowMean,
           previousReturn >= -parameters.threshold,
           currentReturn < -parameters.threshold,
           latest.close < latest.open {
            let entry = latest.close
            let stop = entry + atr * parameters.stopATR
            let risk = stop - entry
            guard parameters.allowsRisk(risk, entry: entry) else { return .noSignal }
            return strategyFixedTargetSignal(
                definition: definition,
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "ETH 15m Momentum Burst: \(parameters.lookback)봉 수익률이 -\(parameters.threshold.riskText)% 임계값을 추세 방향으로 하향 이탈"
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
    let fastMeanPeriod: Int
    let slowMeanPeriod: Int
    let atrPeriod: Int
    let volumeLookback: Int
    let minimumTrendSpread: Decimal
    let maximumTrendSpread: Decimal
    let minimumATRPercent: Decimal
    let maximumATRPercent: Decimal
    let volumeMultiplier: Decimal
    let minimumCloseLocation: Decimal
    let stopATRBuffer: Decimal
    let rewardRiskRatio: Decimal
    let sideMode: Int

    var allowsLong: Bool { sideMode >= 0 }
    var allowsShort: Bool { sideMode <= 0 }

    init(overrides: [String: Decimal]) {
        fastMeanPeriod = intOverride("fastMeanPeriod", overrides: overrides, defaultValue: 96)
        slowMeanPeriod = intOverride("slowMeanPeriod", overrides: overrides, defaultValue: 384)
        atrPeriod = intOverride("atrPeriod", overrides: overrides, defaultValue: 14)
        volumeLookback = intOverride("volumeLookback", overrides: overrides, defaultValue: 96)
        minimumTrendSpread = overrides["minimumTrendSpread"] ?? Decimal(string: "0.004")!
        maximumTrendSpread = overrides["maximumTrendSpread"] ?? Decimal(string: "0.006")!
        minimumATRPercent = overrides["minimumATRPercent"] ?? Decimal(string: "0.001")!
        maximumATRPercent = overrides["maximumATRPercent"] ?? Decimal(string: "0.007")!
        volumeMultiplier = overrides["volumeMultiplier"] ?? Decimal(string: "1.5")!
        minimumCloseLocation = overrides["minimumCloseLocation"] ?? Decimal(string: "0.80")!
        stopATRBuffer = overrides["stopATRBuffer"] ?? Decimal(string: "0.15")!
        rewardRiskRatio = overrides["rewardRiskRatio"] ?? Decimal(string: "2.0")!
        sideMode = sideModeOverride(overrides: overrides)
    }
}

private struct XFrequencyParameters {
    let fastMeanPeriod: Int
    let slowMeanPeriod: Int
    let atrPeriod: Int
    let volumeLookback: Int
    let reclaimLookback: Int
    let minimumTrendSpread: Decimal
    let maximumTrendSpread: Decimal
    let minimumATRPercent: Decimal
    let maximumATRPercent: Decimal
    let volumeMultiplier: Decimal
    let minimumCloseLocation: Decimal
    let stopATRBuffer: Decimal
    let rewardRiskRatio: Decimal
    let sideMode: Int

    var allowsLong: Bool { sideMode >= 0 }
    var allowsShort: Bool { sideMode <= 0 }

    init(overrides: [String: Decimal]) {
        fastMeanPeriod = intOverride("fastMeanPeriod", overrides: overrides, defaultValue: 96)
        slowMeanPeriod = intOverride("slowMeanPeriod", overrides: overrides, defaultValue: 384)
        atrPeriod = intOverride("atrPeriod", overrides: overrides, defaultValue: 14)
        volumeLookback = intOverride("volumeLookback", overrides: overrides, defaultValue: 96)
        reclaimLookback = intOverride("reclaimLookback", overrides: overrides, defaultValue: 3)
        minimumTrendSpread = overrides["minimumTrendSpread"] ?? Decimal(string: "0.001")!
        maximumTrendSpread = overrides["maximumTrendSpread"] ?? Decimal(string: "0.020")!
        minimumATRPercent = overrides["minimumATRPercent"] ?? Decimal(string: "0.001")!
        maximumATRPercent = overrides["maximumATRPercent"] ?? Decimal(string: "0.007")!
        volumeMultiplier = overrides["volumeMultiplier"] ?? Decimal(string: "1.5")!
        minimumCloseLocation = overrides["minimumCloseLocation"] ?? Decimal(string: "0.80")!
        stopATRBuffer = overrides["stopATRBuffer"] ?? Decimal(string: "0.25")!
        rewardRiskRatio = overrides["rewardRiskRatio"] ?? Decimal(string: "2.0")!
        sideMode = sideModeOverride(overrides: overrides)
    }
}

private enum XOneHourReclaimEvaluator {
    static func evaluate(
        _ context: StrategyContext,
        config: StrategyConfig,
        definition: StrategyDefinition,
        side: TradeSide
    ) -> StrategyEvaluation {
        guard context.timeframe == .oneHour else { return .noSignal }

        let candles = context.closedCandles
        let parameters = XOneHourReclaimParameters(overrides: config.parameters)
        guard candles.count >= parameters.slowMeanPeriod,
              let fastMean = candles.simpleMovingAverage(period: parameters.fastMeanPeriod),
              let slowMean = candles.simpleMovingAverage(period: parameters.slowMeanPeriod),
              let atr = candles.averageTrueRange(period: parameters.atrPeriod),
              let averageVolume = candles.averageVolume(period: parameters.volumeLookback),
              candles.count >= 2 else {
            return .noSignal
        }

        let latest = candles[candles.count - 1]
        let previous = candles[candles.count - 2]
        let entry = latest.close
        let range = latest.high - latest.low
        guard entry > 0,
              range > 0,
              atr > 0,
              averageVolume > 0,
              latest.volume >= averageVolume * parameters.volumeMultiplier else {
            return .noSignal
        }

        let trendSpread = absoluteDecimal(fastMean - slowMean) / entry
        let atrPercent = atr / entry
        guard trendSpread >= parameters.minimumTrendSpread,
              trendSpread <= parameters.maximumTrendSpread,
              atrPercent >= parameters.minimumATRPercent,
              atrPercent <= parameters.maximumATRPercent else {
            return .noSignal
        }

        let closeLocation = (latest.close - latest.low) / range

        switch side {
        case .buy:
            guard fastMean > slowMean,
                  latest.low <= fastMean,
                  latest.close > fastMean,
                  latest.close > previous.high,
                  latest.close > latest.open,
                  closeLocation >= parameters.minimumCloseLocation else {
                return .noSignal
            }
            let stop = Swift.min(latest.low, fastMean - atr * parameters.stopATRBuffer)
            let risk = entry - stop
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                definition: definition,
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                takeProfit: entry + risk * parameters.rewardRiskRatio,
                reason: "X 1H Long: SMA24/SMA96 phase spread 상승 추세에서 SMA24 눌림 후 고가 reclaim"
            )
        case .sell:
            guard fastMean < slowMean,
                  latest.high >= fastMean,
                  latest.close < fastMean,
                  latest.close < previous.low,
                  latest.close < latest.open,
                  closeLocation <= 1 - parameters.minimumCloseLocation else {
                return .noSignal
            }
            let stop = Swift.max(latest.high, fastMean + atr * parameters.stopATRBuffer)
            let risk = stop - entry
            guard risk > 0 else { return .noSignal }
            return fixedTargetSignal(
                definition: definition,
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                takeProfit: entry - risk * parameters.rewardRiskRatio,
                reason: "X 1H Short: SMA24/SMA96 phase spread 하락 추세에서 SMA24 되돌림 후 저가 reclaim"
            )
        }
    }

    private static func fixedTargetSignal(
        definition: StrategyDefinition,
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

private struct XOneHourReclaimParameters {
    let fastMeanPeriod: Int
    let slowMeanPeriod: Int
    let atrPeriod: Int
    let volumeLookback: Int
    let minimumTrendSpread: Decimal
    let maximumTrendSpread: Decimal
    let minimumATRPercent: Decimal
    let maximumATRPercent: Decimal
    let volumeMultiplier: Decimal
    let minimumCloseLocation: Decimal
    let stopATRBuffer: Decimal
    let rewardRiskRatio: Decimal

    init(overrides: [String: Decimal]) {
        fastMeanPeriod = intOverride("fastMeanPeriod", overrides: overrides, defaultValue: 24)
        slowMeanPeriod = intOverride("slowMeanPeriod", overrides: overrides, defaultValue: 96)
        atrPeriod = intOverride("atrPeriod", overrides: overrides, defaultValue: 14)
        volumeLookback = intOverride("volumeLookback", overrides: overrides, defaultValue: 48)
        minimumTrendSpread = overrides["minimumTrendSpread"] ?? Decimal(string: "0.002")!
        maximumTrendSpread = overrides["maximumTrendSpread"] ?? Decimal(string: "0.025")!
        minimumATRPercent = overrides["minimumATRPercent"] ?? Decimal(string: "0.0015")!
        maximumATRPercent = overrides["maximumATRPercent"] ?? Decimal(string: "0.012")!
        volumeMultiplier = overrides["volumeMultiplier"] ?? Decimal(string: "1.2")!
        minimumCloseLocation = overrides["minimumCloseLocation"] ?? Decimal(string: "0.72")!
        stopATRBuffer = overrides["stopATRBuffer"] ?? Decimal(string: "0.30")!
        rewardRiskRatio = overrides["rewardRiskRatio"] ?? Decimal(string: "2.2")!
    }
}

private struct ETHFifteenMinuteReclaimParameters {
    let fastMeanPeriod: Int
    let slowMeanPeriod: Int
    let slowSlopeLookback: Int
    let atrPeriod: Int
    let volumeLookback: Int
    let reclaimLookback: Int
    let stopLookback: Int
    let pressureLookback: Int
    let minimumTrendSpread: Decimal
    let maximumTrendSpread: Decimal
    let minimumATRPercent: Decimal
    let maximumATRPercent: Decimal
    let volumeMultiplier: Decimal
    let minimumCloseLocation: Decimal
    let minimumSlope: Decimal
    let minimumPressure: Decimal
    let pullbackATRBuffer: Decimal
    let stopATRBuffer: Decimal
    let minimumStopPercent: Decimal
    let maximumStopPercent: Decimal
    let rewardRiskRatio: Decimal
    let sideMode: Int

    var allowsLong: Bool { sideMode >= 0 }
    var allowsShort: Bool { sideMode <= 0 }

    func allowsRisk(_ risk: Decimal, entry: Decimal) -> Bool {
        guard risk > 0, entry > 0 else { return false }
        let riskPercent = risk / entry
        return riskPercent >= minimumStopPercent && riskPercent <= maximumStopPercent
    }

    init(overrides: [String: Decimal]) {
        fastMeanPeriod = intOverride("fastMeanPeriod", overrides: overrides, defaultValue: 48)
        slowMeanPeriod = intOverride("slowMeanPeriod", overrides: overrides, defaultValue: 192)
        slowSlopeLookback = intOverride("slowSlopeLookback", overrides: overrides, defaultValue: 24)
        atrPeriod = intOverride("atrPeriod", overrides: overrides, defaultValue: 14)
        volumeLookback = intOverride("volumeLookback", overrides: overrides, defaultValue: 64)
        reclaimLookback = intOverride("reclaimLookback", overrides: overrides, defaultValue: 4)
        stopLookback = intOverride("stopLookback", overrides: overrides, defaultValue: 8)
        pressureLookback = intOverride("pressureLookback", overrides: overrides, defaultValue: 12)
        minimumTrendSpread = overrides["minimumTrendSpread"] ?? Decimal(string: "0.0015")!
        maximumTrendSpread = overrides["maximumTrendSpread"] ?? Decimal(string: "0.035")!
        minimumATRPercent = overrides["minimumATRPercent"] ?? Decimal(string: "0.0015")!
        maximumATRPercent = overrides["maximumATRPercent"] ?? Decimal(string: "0.012")!
        volumeMultiplier = overrides["volumeMultiplier"] ?? Decimal(string: "1.05")!
        minimumCloseLocation = overrides["minimumCloseLocation"] ?? Decimal(string: "0.66")!
        minimumSlope = overrides["minimumSlope"] ?? Decimal(string: "0.0008")!
        minimumPressure = overrides["minimumPressure"] ?? Decimal(string: "0.02")!
        pullbackATRBuffer = overrides["pullbackATRBuffer"] ?? Decimal(string: "0.20")!
        stopATRBuffer = overrides["stopATRBuffer"] ?? Decimal(string: "0.15")!
        minimumStopPercent = overrides["minimumStopPercent"] ?? Decimal(string: "0.001")!
        maximumStopPercent = overrides["maximumStopPercent"] ?? Decimal(string: "0.0045")!
        rewardRiskRatio = overrides["rewardRiskRatio"] ?? Decimal(string: "2.1")!
        sideMode = sideModeOverride(overrides: overrides)
    }
}

private struct ETHFifteenMinuteCompressionBreakoutParameters {
    let trendFastPeriod: Int
    let trendSlowPeriod: Int
    let atrPeriod: Int
    let shortRangePeriod: Int
    let longRangePeriod: Int
    let volumeLookback: Int
    let breakoutLookback: Int
    let maximumCompressionRatio: Decimal
    let minimumTrendSpread: Decimal
    let maximumTrendSpread: Decimal
    let minimumATRPercent: Decimal
    let maximumATRPercent: Decimal
    let volumeMultiplier: Decimal
    let breakoutATRBuffer: Decimal
    let stopATR: Decimal
    let rewardRiskRatio: Decimal
    let sideMode: Int

    var allowsLong: Bool { sideMode >= 0 }
    var allowsShort: Bool { sideMode <= 0 }

    init(overrides: [String: Decimal]) {
        trendFastPeriod = intOverride("trendFastPeriod", overrides: overrides, defaultValue: 64)
        trendSlowPeriod = intOverride("trendSlowPeriod", overrides: overrides, defaultValue: 256)
        atrPeriod = intOverride("atrPeriod", overrides: overrides, defaultValue: 14)
        shortRangePeriod = intOverride("shortRangePeriod", overrides: overrides, defaultValue: 12)
        longRangePeriod = intOverride("longRangePeriod", overrides: overrides, defaultValue: 96)
        volumeLookback = intOverride("volumeLookback", overrides: overrides, defaultValue: 80)
        breakoutLookback = intOverride("breakoutLookback", overrides: overrides, defaultValue: 18)
        maximumCompressionRatio = overrides["maximumCompressionRatio"] ?? Decimal(string: "0.88")!
        minimumTrendSpread = overrides["minimumTrendSpread"] ?? Decimal(string: "0.001")!
        maximumTrendSpread = overrides["maximumTrendSpread"] ?? Decimal(string: "0.045")!
        minimumATRPercent = overrides["minimumATRPercent"] ?? Decimal(string: "0.0012")!
        maximumATRPercent = overrides["maximumATRPercent"] ?? Decimal(string: "0.012")!
        volumeMultiplier = overrides["volumeMultiplier"] ?? Decimal(string: "1.15")!
        breakoutATRBuffer = overrides["breakoutATRBuffer"] ?? Decimal(string: "0.05")!
        stopATR = overrides["stopATR"] ?? Decimal(string: "1.15")!
        rewardRiskRatio = overrides["rewardRiskRatio"] ?? Decimal(string: "2.2")!
        sideMode = sideModeOverride(overrides: overrides)
    }
}

private struct ETHFifteenMinuteVWMAReversionParameters {
    let vwmaPeriod: Int
    let trendFastPeriod: Int
    let trendSlowPeriod: Int
    let atrPeriod: Int
    let volumeLookback: Int
    let maximumTrendSpread: Decimal
    let minimumATRPercent: Decimal
    let maximumATRPercent: Decimal
    let volumeMultiplier: Decimal
    let bandATR: Decimal
    let stopATRBuffer: Decimal
    let minimumCloseLocation: Decimal
    let rewardRiskRatio: Decimal
    let sideMode: Int

    var allowsLong: Bool { sideMode >= 0 }
    var allowsShort: Bool { sideMode <= 0 }

    init(overrides: [String: Decimal]) {
        vwmaPeriod = intOverride("vwmaPeriod", overrides: overrides, defaultValue: 96)
        trendFastPeriod = intOverride("trendFastPeriod", overrides: overrides, defaultValue: 48)
        trendSlowPeriod = intOverride("trendSlowPeriod", overrides: overrides, defaultValue: 192)
        atrPeriod = intOverride("atrPeriod", overrides: overrides, defaultValue: 14)
        volumeLookback = intOverride("volumeLookback", overrides: overrides, defaultValue: 64)
        maximumTrendSpread = overrides["maximumTrendSpread"] ?? Decimal(string: "0.018")!
        minimumATRPercent = overrides["minimumATRPercent"] ?? Decimal(string: "0.0015")!
        maximumATRPercent = overrides["maximumATRPercent"] ?? Decimal(string: "0.012")!
        volumeMultiplier = overrides["volumeMultiplier"] ?? Decimal(string: "0.85")!
        bandATR = overrides["bandATR"] ?? Decimal(string: "1.45")!
        stopATRBuffer = overrides["stopATRBuffer"] ?? Decimal(string: "0.20")!
        minimumCloseLocation = overrides["minimumCloseLocation"] ?? Decimal(string: "0.68")!
        rewardRiskRatio = overrides["rewardRiskRatio"] ?? Decimal(string: "2.0")!
        sideMode = sideModeOverride(overrides: overrides)
    }
}

private struct ETHFifteenMinuteMomentumBurstParameters {
    let lookback: Int
    let threshold: Decimal
    let fastMeanPeriod: Int
    let slowMeanPeriod: Int
    let atrPeriod: Int
    let volumeLookback: Int
    let minimumATRPercent: Decimal
    let maximumATRPercent: Decimal
    let volumeMultiplier: Decimal
    let stopATR: Decimal
    let minimumStopPercent: Decimal
    let maximumStopPercent: Decimal
    let rewardRiskRatio: Decimal
    let sideMode: Int

    var allowsLong: Bool { sideMode >= 0 }
    var allowsShort: Bool { sideMode <= 0 }

    func allowsRisk(_ risk: Decimal, entry: Decimal) -> Bool {
        guard risk > 0, entry > 0 else { return false }
        let riskPercent = risk / entry
        return riskPercent >= minimumStopPercent && riskPercent <= maximumStopPercent
    }

    init(overrides: [String: Decimal]) {
        lookback = intOverride("lookback", overrides: overrides, defaultValue: 48)
        threshold = overrides["threshold"] ?? Decimal(string: "0.025")!
        fastMeanPeriod = intOverride("fastMeanPeriod", overrides: overrides, defaultValue: 96)
        slowMeanPeriod = intOverride("slowMeanPeriod", overrides: overrides, defaultValue: 384)
        atrPeriod = intOverride("atrPeriod", overrides: overrides, defaultValue: 14)
        volumeLookback = intOverride("volumeLookback", overrides: overrides, defaultValue: 96)
        minimumATRPercent = overrides["minimumATRPercent"] ?? Decimal(string: "0.0012")!
        maximumATRPercent = overrides["maximumATRPercent"] ?? Decimal(string: "0.018")!
        volumeMultiplier = overrides["volumeMultiplier"] ?? Decimal(string: "0.90")!
        stopATR = overrides["stopATR"] ?? Decimal(string: "1.20")!
        minimumStopPercent = overrides["minimumStopPercent"] ?? Decimal(string: "0.001")!
        maximumStopPercent = overrides["maximumStopPercent"] ?? Decimal(string: "0.006")!
        rewardRiskRatio = overrides["rewardRiskRatio"] ?? Decimal(string: "2.5")!
        sideMode = sideModeOverride(overrides: overrides)
    }
}

private struct ETHOneHourMomentumBurstParameters {
    let lookback: Int
    let threshold: Decimal
    let fastMeanPeriod: Int
    let slowMeanPeriod: Int
    let slowSlopeLookback: Int
    let atrPeriod: Int
    let volumeLookback: Int
    let pressureLookback: Int
    let minimumATRPercent: Decimal
    let maximumATRPercent: Decimal
    let minimumSlope: Decimal
    let minimumPressure: Decimal
    let volumeMultiplier: Decimal
    let stopATR: Decimal
    let minimumStopPercent: Decimal
    let maximumStopPercent: Decimal
    let rewardRiskRatio: Decimal
    let sideMode: Int

    var allowsLong: Bool { sideMode >= 0 }
    var allowsShort: Bool { sideMode <= 0 }

    func allowsRisk(_ risk: Decimal, entry: Decimal) -> Bool {
        guard risk > 0, entry > 0 else { return false }
        let riskPercent = risk / entry
        return riskPercent >= minimumStopPercent && riskPercent <= maximumStopPercent
    }

    init(overrides: [String: Decimal]) {
        lookback = intOverride("lookback", overrides: overrides, defaultValue: 12)
        threshold = overrides["threshold"] ?? Decimal(string: "0.04")!
        fastMeanPeriod = intOverride("fastMeanPeriod", overrides: overrides, defaultValue: 24)
        slowMeanPeriod = intOverride("slowMeanPeriod", overrides: overrides, defaultValue: 96)
        slowSlopeLookback = intOverride("slowSlopeLookback", overrides: overrides, defaultValue: 24)
        atrPeriod = intOverride("atrPeriod", overrides: overrides, defaultValue: 14)
        volumeLookback = intOverride("volumeLookback", overrides: overrides, defaultValue: 48)
        pressureLookback = intOverride("pressureLookback", overrides: overrides, defaultValue: 12)
        minimumATRPercent = overrides["minimumATRPercent"] ?? Decimal(string: "0.002")!
        maximumATRPercent = overrides["maximumATRPercent"] ?? Decimal(string: "0.025")!
        minimumSlope = overrides["minimumSlope"] ?? 0
        minimumPressure = overrides["minimumPressure"] ?? 0
        volumeMultiplier = overrides["volumeMultiplier"] ?? Decimal(string: "0.95")!
        stopATR = overrides["stopATR"] ?? Decimal(string: "1.20")!
        minimumStopPercent = overrides["minimumStopPercent"] ?? Decimal(string: "0.0015")!
        maximumStopPercent = overrides["maximumStopPercent"] ?? Decimal(string: "0.019")!
        rewardRiskRatio = overrides["rewardRiskRatio"] ?? Decimal(string: "2.5")!
        sideMode = sideModeOverride(overrides: overrides)
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

private func sideModeOverride(overrides: [String: Decimal]) -> Int {
    guard let value = overrides["sideMode"] else { return 0 }
    return min(1, max(-1, Int(truncating: NSDecimalNumber(decimal: value))))
}

private func strategyFixedTargetSignal(
    definition: StrategyDefinition,
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

private extension Array where Element == Candle {
    func simpleMovingAverage(period: Int, endingAt index: Int? = nil) -> Decimal? {
        let endIndex = index ?? count - 1
        guard period > 0,
              endIndex >= 0,
              endIndex < count,
              endIndex - period + 1 >= 0 else {
            return nil
        }

        var total: Decimal = 0
        for candle in self[(endIndex - period + 1)...endIndex] {
            total += candle.close
        }
        return total / Decimal(period)
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
