import Foundation

private enum StrategyParameter {
    static let rewardRisk = "rewardRisk"
    static let atrMultiple = "atrMultiple"
}

struct TrendPullbackStrategy: TradingStrategy {
    static let identifier = "trend-pullback"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "추세 눌림목",
        summary: "EMA 추세 안에서 RSI가 되살아나는 눌림목만 진입",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 3,
            parameters: [
                StrategyParameter.rewardRisk: 2.2,
                StrategyParameter.atrMultiple: 1.2
            ]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        let candles = context.closedCandles
        guard candles.count >= 210,
              let ema50 = TechnicalIndicators.emaClose(candles, period: 50),
              let ema200 = TechnicalIndicators.emaClose(candles, period: 200),
              let previousEma50 = TechnicalIndicators.emaClose(candles, period: 50, endOffset: 1),
              let rsi = TechnicalIndicators.rsi(candles, period: 14),
              let previousRSI = TechnicalIndicators.rsi(candles, period: 14, endOffset: 1),
              let atr = TechnicalIndicators.atr(candles, period: 14),
              let close = TechnicalIndicators.close(candles),
              let previousClose = TechnicalIndicators.close(candles, endOffset: 1) else {
            return .noSignal
        }

        let rewardRisk = config.doubleValue(StrategyParameter.rewardRisk, default: 2.2)
        let atrMultiple = config.doubleValue(StrategyParameter.atrMultiple, default: 1.2)

        if ema50 > ema200,
           ema50 >= previousEma50,
           previousClose <= ema50,
           close > ema50,
           previousRSI < 50,
           (50...64).contains(rsi) {
            let entry = close
            let recentLow = TechnicalIndicators.lowestLow(candles, period: 5) ?? entry - atr * atrMultiple
            let stop = min(recentLow, entry - atr * atrMultiple)
            return signal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "상승 추세에서 EMA50을 되찾고 RSI가 50 위로 회복"
            )
        }

        if ema50 < ema200,
           ema50 <= previousEma50,
           previousClose >= ema50,
           close < ema50,
           previousRSI > 50,
           (36...50).contains(rsi) {
            let entry = close
            let recentHigh = TechnicalIndicators.highestHigh(candles, period: 5) ?? entry + atr * atrMultiple
            let stop = max(recentHigh, entry + atr * atrMultiple)
            return signal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "하락 추세에서 EMA50 아래로 재이탈하고 RSI가 50 아래로 약화"
            )
        }

        return .noSignal
    }
}

struct VWMAReclaimStrategy: TradingStrategy {
    static let identifier = "vwma-reclaim"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "VWMA 회복",
        summary: "거래량이 실린 VWMA 재돌파/재이탈만 진입",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 3,
            parameters: [
                StrategyParameter.rewardRisk: 2.1,
                StrategyParameter.atrMultiple: 1.0
            ]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        let candles = context.closedCandles
        guard candles.count >= 80,
              let vwma = TechnicalIndicators.vwmaClose(candles, period: 20),
              let previousVWMA = TechnicalIndicators.vwmaClose(candles, period: 20, endOffset: 1),
              let ema50 = TechnicalIndicators.emaClose(candles, period: 50),
              let atr = TechnicalIndicators.atr(candles, period: 14),
              let volumeAverage = TechnicalIndicators.volumeSMA(candles, period: 20, endOffset: 1),
              let close = TechnicalIndicators.close(candles),
              let previousClose = TechnicalIndicators.close(candles, endOffset: 1) else {
            return .noSignal
        }

        let currentVolume = NSDecimalNumber(decimal: candles[candles.count - 1].volume).doubleValue
        let rewardRisk = config.doubleValue(StrategyParameter.rewardRisk, default: 2.1)
        let atrMultiple = config.doubleValue(StrategyParameter.atrMultiple, default: 1.0)
        let volumeConfirmed = currentVolume >= volumeAverage * 1.05

        if volumeConfirmed,
           previousClose <= previousVWMA,
           close > vwma,
           vwma > ema50 {
            let entry = close
            let stop = min(TechnicalIndicators.lowestLow(candles, period: 4) ?? entry - atr, entry - atr * atrMultiple)
            return signal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "평균보다 큰 거래량으로 VWMA를 회복"
            )
        }

        if volumeConfirmed,
           previousClose >= previousVWMA,
           close < vwma,
           vwma < ema50 {
            let entry = close
            let stop = max(TechnicalIndicators.highestHigh(candles, period: 4) ?? entry + atr, entry + atr * atrMultiple)
            return signal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "평균보다 큰 거래량으로 VWMA 아래에 재진입"
            )
        }

        return .noSignal
    }
}

struct BollingerRSIReversionStrategy: TradingStrategy {
    static let identifier = "bollinger-rsi-reversion"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "볼린저 RSI 반등",
        summary: "밴드 이탈 후 재진입과 RSI 과열 해소를 함께 확인",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                StrategyParameter.rewardRisk: 2.05,
                StrategyParameter.atrMultiple: 0.8
            ]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        let candles = context.closedCandles
        guard candles.count >= 40,
              let bands = TechnicalIndicators.bollingerBands(candles, period: 20, standardDeviationMultiplier: 2),
              let previousBands = TechnicalIndicators.bollingerBands(candles, period: 20, standardDeviationMultiplier: 2, endOffset: 1),
              let rsi = TechnicalIndicators.rsi(candles, period: 14),
              let atr = TechnicalIndicators.atr(candles, period: 14),
              let close = TechnicalIndicators.close(candles),
              let previousClose = TechnicalIndicators.close(candles, endOffset: 1) else {
            return .noSignal
        }

        let rewardRisk = config.doubleValue(StrategyParameter.rewardRisk, default: 2.05)
        let atrMultiple = config.doubleValue(StrategyParameter.atrMultiple, default: 0.8)
        let bandSlopeIsFlatEnough = abs(bands.middle - previousBands.middle) / max(abs(previousBands.middle), 1) < 0.006

        if bandSlopeIsFlatEnough,
           previousClose < previousBands.lower,
           close > bands.lower,
           rsi <= 42 {
            let entry = close
            let stop = min(TechnicalIndicators.lowestLow(candles, period: 3) ?? entry - atr, entry - atr * atrMultiple)
            return signal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "하단 밴드 밖으로 밀린 뒤 밴드 안으로 복귀하고 RSI 과매도권 확인"
            )
        }

        if bandSlopeIsFlatEnough,
           previousClose > previousBands.upper,
           close < bands.upper,
           rsi >= 58 {
            let entry = close
            let stop = max(TechnicalIndicators.highestHigh(candles, period: 3) ?? entry + atr, entry + atr * atrMultiple)
            return signal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "상단 밴드 밖으로 튄 뒤 밴드 안으로 복귀하고 RSI 과열권 확인"
            )
        }

        return .noSignal
    }
}

struct VolumeBreakoutStrategy: TradingStrategy {
    static let identifier = "volume-breakout"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "거래량 돌파",
        summary: "박스권 고점/저점 돌파가 평균 거래량을 동반할 때만 진입",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                StrategyParameter.rewardRisk: 2.5,
                StrategyParameter.atrMultiple: 1.4
            ]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        let candles = context.closedCandles
        guard candles.count >= 80,
              let previousHigh = TechnicalIndicators.highestHigh(candles, period: 24, endOffset: 1),
              let previousLow = TechnicalIndicators.lowestLow(candles, period: 24, endOffset: 1),
              let volumeAverage = TechnicalIndicators.volumeSMA(candles, period: 24, endOffset: 1),
              let ema50 = TechnicalIndicators.emaClose(candles, period: 50),
              let previousEma50 = TechnicalIndicators.emaClose(candles, period: 50, endOffset: 1),
              let atr = TechnicalIndicators.atr(candles, period: 14),
              let close = TechnicalIndicators.close(candles) else {
            return .noSignal
        }

        let currentVolume = NSDecimalNumber(decimal: candles[candles.count - 1].volume).doubleValue
        guard currentVolume >= volumeAverage * 1.35 else { return .noSignal }

        let rewardRisk = config.doubleValue(StrategyParameter.rewardRisk, default: 2.5)
        let atrMultiple = config.doubleValue(StrategyParameter.atrMultiple, default: 1.4)

        if close > previousHigh, ema50 >= previousEma50 {
            let entry = close
            let stop = min(previousHigh, entry - atr * atrMultiple)
            return signal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "24봉 고점을 거래량과 함께 돌파"
            )
        }

        if close < previousLow, ema50 <= previousEma50 {
            let entry = close
            let stop = max(previousLow, entry + atr * atrMultiple)
            return signal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "24봉 저점을 거래량과 함께 이탈"
            )
        }

        return .noSignal
    }
}

struct RSITrendContinuationStrategy: TradingStrategy {
    static let identifier = "rsi-trend-continuation"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "RSI 추세 지속",
        summary: "큰 추세 방향으로 RSI 중심선 회복/이탈만 진입",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 3,
            parameters: [
                StrategyParameter.rewardRisk: 2.1,
                StrategyParameter.atrMultiple: 1.1
            ]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        let candles = context.closedCandles
        guard candles.count >= 160,
              let ema34 = TechnicalIndicators.emaClose(candles, period: 34),
              let ema144 = TechnicalIndicators.emaClose(candles, period: 144),
              let rsi = TechnicalIndicators.rsi(candles, period: 14),
              let previousRSI = TechnicalIndicators.rsi(candles, period: 14, endOffset: 1),
              let vwma = TechnicalIndicators.vwmaClose(candles, period: 20),
              let atr = TechnicalIndicators.atr(candles, period: 14),
              let close = TechnicalIndicators.close(candles) else {
            return .noSignal
        }

        let rewardRisk = config.doubleValue(StrategyParameter.rewardRisk, default: 2.1)
        let atrMultiple = config.doubleValue(StrategyParameter.atrMultiple, default: 1.1)

        if ema34 > ema144,
           close > vwma,
           previousRSI < 50,
           (50...62).contains(rsi) {
            let entry = close
            let stop = min(TechnicalIndicators.lowestLow(candles, period: 6) ?? entry - atr, entry - atr * atrMultiple)
            return signal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "상승 추세에서 RSI가 중심선을 회복"
            )
        }

        if ema34 < ema144,
           close < vwma,
           previousRSI > 50,
           (38...50).contains(rsi) {
            let entry = close
            let stop = max(TechnicalIndicators.highestHigh(candles, period: 6) ?? entry + atr, entry + atr * atrMultiple)
            return signal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "하락 추세에서 RSI가 중심선을 이탈"
            )
        }

        return .noSignal
    }
}

struct KeltnerATRPullbackStrategy: TradingStrategy {
    static let identifier = "keltner-atr-pullback"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "Keltner ATR 눌림목",
        summary: "EMA 추세 안에서 Keltner 채널 하단/상단 회복만 진입",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 3,
            parameters: [
                StrategyParameter.rewardRisk: 2.15,
                StrategyParameter.atrMultiple: 1.05
            ]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        let candles = context.closedCandles
        guard candles.count >= 210,
              let channels = TechnicalIndicators.keltnerChannels(candles, period: 20, atrPeriod: 14, atrMultiplier: 1.5),
              let previousChannels = TechnicalIndicators.keltnerChannels(candles, period: 20, atrPeriod: 14, atrMultiplier: 1.5, endOffset: 1),
              let ema50 = TechnicalIndicators.emaClose(candles, period: 50),
              let ema200 = TechnicalIndicators.emaClose(candles, period: 200),
              let rsi = TechnicalIndicators.rsi(candles, period: 14),
              let atr = TechnicalIndicators.atr(candles, period: 14),
              let close = TechnicalIndicators.close(candles),
              let previousClose = TechnicalIndicators.close(candles, endOffset: 1) else {
            return .noSignal
        }

        let rewardRisk = config.doubleValue(StrategyParameter.rewardRisk, default: 2.15)
        let atrMultiple = config.doubleValue(StrategyParameter.atrMultiple, default: 1.05)

        if ema50 > ema200,
           previousClose < previousChannels.lower,
           close > channels.lower,
           close > channels.middle,
           (44...62).contains(rsi) {
            let entry = close
            let stop = min(TechnicalIndicators.lowestLow(candles, period: 5) ?? entry - atr, entry - atr * atrMultiple)
            return signal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "상승 추세에서 Keltner 하단 이탈 후 중심선 위로 회복"
            )
        }

        if ema50 < ema200,
           previousClose > previousChannels.upper,
           close < channels.upper,
           close < channels.middle,
           (38...56).contains(rsi) {
            let entry = close
            let stop = max(TechnicalIndicators.highestHigh(candles, period: 5) ?? entry + atr, entry + atr * atrMultiple)
            return signal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "하락 추세에서 Keltner 상단 이탈 후 중심선 아래로 복귀"
            )
        }

        return .noSignal
    }
}

struct DonchianTrendBreakoutStrategy: TradingStrategy {
    static let identifier = "donchian-trend-breakout"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "Donchian 추세 돌파",
        summary: "장기 박스권 돌파를 EMA 추세와 거래량으로 필터링",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                StrategyParameter.rewardRisk: 2.8,
                StrategyParameter.atrMultiple: 1.6
            ]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        let candles = context.closedCandles
        guard candles.count >= 220,
              let channelHigh = TechnicalIndicators.highestHigh(candles, period: 55, endOffset: 1),
              let channelLow = TechnicalIndicators.lowestLow(candles, period: 55, endOffset: 1),
              let ema50 = TechnicalIndicators.emaClose(candles, period: 50),
              let ema200 = TechnicalIndicators.emaClose(candles, period: 200),
              let previousEma50 = TechnicalIndicators.emaClose(candles, period: 50, endOffset: 1),
              let volumeAverage = TechnicalIndicators.volumeSMA(candles, period: 30, endOffset: 1),
              let atr = TechnicalIndicators.atr(candles, period: 14),
              let close = TechnicalIndicators.close(candles) else {
            return .noSignal
        }

        let currentVolume = NSDecimalNumber(decimal: candles[candles.count - 1].volume).doubleValue
        guard currentVolume >= volumeAverage * 1.2 else { return .noSignal }

        let rewardRisk = config.doubleValue(StrategyParameter.rewardRisk, default: 2.8)
        let atrMultiple = config.doubleValue(StrategyParameter.atrMultiple, default: 1.6)

        if close > channelHigh,
           ema50 > ema200,
           ema50 >= previousEma50 {
            let entry = close
            let stop = min(channelHigh, entry - atr * atrMultiple)
            return signal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "55봉 Donchian 상단을 추세와 거래량 확인 후 돌파"
            )
        }

        if close < channelLow,
           ema50 < ema200,
           ema50 <= previousEma50 {
            let entry = close
            let stop = max(channelLow, entry + atr * atrMultiple)
            return signal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "55봉 Donchian 하단을 추세와 거래량 확인 후 이탈"
            )
        }

        return .noSignal
    }
}

struct SuperTrendATRContinuationStrategy: TradingStrategy {
    static let identifier = "supertrend-atr-continuation"

    let definition = StrategyDefinition(
        id: Self.identifier,
        name: "SuperTrend ATR 지속",
        summary: "SuperTrend 방향 전환을 EMA/VWMA 추세와 함께 확인",
        defaultConfig: StrategyConfig(
            strategyID: Self.identifier,
            leverage: 2,
            parameters: [
                StrategyParameter.rewardRisk: 2.3,
                StrategyParameter.atrMultiple: 1.2
            ]
        )
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        let candles = context.closedCandles
        guard candles.count >= 220,
              let trend = TechnicalIndicators.superTrend(candles, period: 10, multiplier: 3),
              let previousTrend = TechnicalIndicators.superTrend(candles, period: 10, multiplier: 3, endOffset: 1),
              let ema50 = TechnicalIndicators.emaClose(candles, period: 50),
              let ema200 = TechnicalIndicators.emaClose(candles, period: 200),
              let vwma = TechnicalIndicators.vwmaClose(candles, period: 20),
              let atr = TechnicalIndicators.atr(candles, period: 14),
              let close = TechnicalIndicators.close(candles) else {
            return .noSignal
        }

        let rewardRisk = config.doubleValue(StrategyParameter.rewardRisk, default: 2.3)
        let atrMultiple = config.doubleValue(StrategyParameter.atrMultiple, default: 1.2)

        if previousTrend.direction < 0,
           trend.direction > 0,
           close > trend.line,
           close > vwma,
           ema50 > ema200 {
            let entry = close
            let stop = min(trend.line, entry - atr * atrMultiple)
            return signal(
                context: context,
                side: .buy,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "SuperTrend가 상승 전환했고 EMA/VWMA 추세가 같은 방향"
            )
        }

        if previousTrend.direction > 0,
           trend.direction < 0,
           close < trend.line,
           close < vwma,
           ema50 < ema200 {
            let entry = close
            let stop = max(trend.line, entry + atr * atrMultiple)
            return signal(
                context: context,
                side: .sell,
                entry: entry,
                stop: stop,
                rewardRisk: rewardRisk,
                reason: "SuperTrend가 하락 전환했고 EMA/VWMA 추세가 같은 방향"
            )
        }

        return .noSignal
    }
}

private extension TradingStrategy {
    func signal(
        context: StrategyContext,
        side: TradeSide,
        entry: Double,
        stop: Double,
        rewardRisk: Double,
        reason: String
    ) -> StrategyEvaluation {
        let risk = abs(entry - stop)
        guard entry > 0, risk > 0, rewardRisk > 0 else { return .noSignal }
        let takeProfit: Double
        switch side {
        case .buy:
            guard stop < entry else { return .noSignal }
            takeProfit = entry + risk * rewardRisk
        case .sell:
            guard stop > entry else { return .noSignal }
            takeProfit = entry - risk * rewardRisk
        }

        let draft = StrategySignalDraft(
            strategyID: definition.id,
            symbol: context.symbol,
            side: side,
            entryPrice: TechnicalIndicators.decimal(entry),
            stopLoss: TechnicalIndicators.decimal(stop),
            takeProfit: TechnicalIndicators.decimal(takeProfit),
            reason: reason,
            generatedAt: context.generatedAt
        )
        guard let signal = try? draft.validated() else { return .noSignal }
        return .signal(signal)
    }
}

private extension StrategyConfig {
    func doubleValue(_ key: String, default defaultValue: Double) -> Double {
        guard let value = parameters[key] else { return defaultValue }
        return NSDecimalNumber(decimal: value).doubleValue
    }
}
