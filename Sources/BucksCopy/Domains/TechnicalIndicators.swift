import Foundation

enum TechnicalIndicators {
    static func smaClose(_ candles: [Candle], period: Int, endOffset: Int = 0) -> Double? {
        average(candles, period: period, endOffset: endOffset) { decimalDouble($0.close) }
    }

    static func emaClose(_ candles: [Candle], period: Int, endOffset: Int = 0) -> Double? {
        guard period > 1 else { return close(candles, endOffset: endOffset) }
        guard let endIndex = endingIndex(candles, endOffset: endOffset) else { return nil }
        let warmup = min(period * 3, endIndex + 1)
        guard warmup >= period else { return nil }
        let startIndex = endIndex - warmup + 1
        let multiplier = 2.0 / Double(period + 1)
        var ema = decimalDouble(candles[startIndex].close)
        guard startIndex < endIndex else { return ema }
        for index in (startIndex + 1)...endIndex {
            let price = decimalDouble(candles[index].close)
            ema = (price - ema) * multiplier + ema
        }
        return ema
    }

    static func rsi(_ candles: [Candle], period: Int, endOffset: Int = 0) -> Double? {
        guard period > 1, let endIndex = endingIndex(candles, endOffset: endOffset) else { return nil }
        let startIndex = endIndex - period
        guard startIndex >= 0 else { return nil }

        var gains = 0.0
        var losses = 0.0
        for index in (startIndex + 1)...endIndex {
            let change = decimalDouble(candles[index].close - candles[index - 1].close)
            if change >= 0 {
                gains += change
            } else {
                losses += abs(change)
            }
        }

        guard losses > 0 else { return 100 }
        let relativeStrength = gains / losses
        return 100 - (100 / (1 + relativeStrength))
    }

    static func atr(_ candles: [Candle], period: Int, endOffset: Int = 0) -> Double? {
        guard period > 1, let endIndex = endingIndex(candles, endOffset: endOffset) else { return nil }
        let startIndex = endIndex - period + 1
        guard startIndex > 0 else { return nil }

        var total = 0.0
        for index in startIndex...endIndex {
            let high = decimalDouble(candles[index].high)
            let low = decimalDouble(candles[index].low)
            let previousClose = decimalDouble(candles[index - 1].close)
            let trueRange = max(high - low, abs(high - previousClose), abs(previousClose - low))
            total += trueRange
        }
        return total / Double(period)
    }

    static func vwmaClose(_ candles: [Candle], period: Int, endOffset: Int = 0) -> Double? {
        guard let range = range(candles, period: period, endOffset: endOffset) else { return nil }
        var weightedPrice = 0.0
        var totalVolume = 0.0
        for index in range {
            let volume = max(decimalDouble(candles[index].volume), 0)
            weightedPrice += decimalDouble(candles[index].close) * volume
            totalVolume += volume
        }
        guard totalVolume > 0 else { return nil }
        return weightedPrice / totalVolume
    }

    static func volumeSMA(_ candles: [Candle], period: Int, endOffset: Int = 0) -> Double? {
        average(candles, period: period, endOffset: endOffset) { decimalDouble($0.volume) }
    }

    static func bollingerBands(
        _ candles: [Candle],
        period: Int,
        standardDeviationMultiplier: Double,
        endOffset: Int = 0
    ) -> (lower: Double, middle: Double, upper: Double)? {
        guard let range = range(candles, period: period, endOffset: endOffset) else { return nil }
        let values = range.map { decimalDouble(candles[$0].close) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        let standardDeviation = sqrt(variance)
        return (
            lower: mean - standardDeviation * standardDeviationMultiplier,
            middle: mean,
            upper: mean + standardDeviation * standardDeviationMultiplier
        )
    }

    static func keltnerChannels(
        _ candles: [Candle],
        period: Int,
        atrPeriod: Int,
        atrMultiplier: Double,
        endOffset: Int = 0
    ) -> (lower: Double, middle: Double, upper: Double)? {
        guard let middle = emaClose(candles, period: period, endOffset: endOffset),
              let averageTrueRange = atr(candles, period: atrPeriod, endOffset: endOffset) else {
            return nil
        }
        let width = averageTrueRange * atrMultiplier
        return (lower: middle - width, middle: middle, upper: middle + width)
    }

    static func superTrend(
        _ candles: [Candle],
        period: Int,
        multiplier: Double,
        endOffset: Int = 0
    ) -> (direction: Int, line: Double)? {
        guard period > 1, multiplier > 0, let endIndex = endingIndex(candles, endOffset: endOffset) else {
            return nil
        }
        guard endIndex >= period else { return nil }

        var trueRanges: [Double] = []
        trueRanges.reserveCapacity(endIndex + 1)
        for index in 0...endIndex {
            let high = decimalDouble(candles[index].high)
            let low = decimalDouble(candles[index].low)
            guard index > 0 else {
                trueRanges.append(high - low)
                continue
            }
            let previousClose = decimalDouble(candles[index - 1].close)
            trueRanges.append(max(high - low, abs(high - previousClose), abs(previousClose - low)))
        }

        let firstATR = trueRanges[1...period].reduce(0, +) / Double(period)
        let firstCandle = candles[period]
        let firstMedian = (decimalDouble(firstCandle.high) + decimalDouble(firstCandle.low)) / 2
        var finalUpper = firstMedian + multiplier * firstATR
        var finalLower = firstMedian - multiplier * firstATR
        var direction = decimalDouble(firstCandle.close) >= finalLower ? 1 : -1

        guard period < endIndex else {
            return (direction: direction, line: direction == 1 ? finalLower : finalUpper)
        }

        for index in (period + 1)...endIndex {
            let rangeStart = max(1, index - period + 1)
            let atrValue = trueRanges[rangeStart...index].reduce(0, +) / Double(index - rangeStart + 1)
            let candle = candles[index]
            let previousClose = decimalDouble(candles[index - 1].close)
            let close = decimalDouble(candle.close)
            let median = (decimalDouble(candle.high) + decimalDouble(candle.low)) / 2
            let basicUpper = median + multiplier * atrValue
            let basicLower = median - multiplier * atrValue

            finalUpper = basicUpper < finalUpper || previousClose > finalUpper ? basicUpper : finalUpper
            finalLower = basicLower > finalLower || previousClose < finalLower ? basicLower : finalLower

            if direction == 1 {
                direction = close < finalLower ? -1 : 1
            } else {
                direction = close > finalUpper ? 1 : -1
            }
        }

        return (direction: direction, line: direction == 1 ? finalLower : finalUpper)
    }

    static func highestHigh(_ candles: [Candle], period: Int, endOffset: Int = 0) -> Double? {
        guard let range = range(candles, period: period, endOffset: endOffset) else { return nil }
        return range.map { decimalDouble(candles[$0].high) }.max()
    }

    static func lowestLow(_ candles: [Candle], period: Int, endOffset: Int = 0) -> Double? {
        guard let range = range(candles, period: period, endOffset: endOffset) else { return nil }
        return range.map { decimalDouble(candles[$0].low) }.min()
    }

    static func close(_ candles: [Candle], endOffset: Int = 0) -> Double? {
        guard let index = endingIndex(candles, endOffset: endOffset) else { return nil }
        return decimalDouble(candles[index].close)
    }

    static func decimal(_ value: Double) -> Decimal {
        Decimal(value)
    }

    private static func average(
        _ candles: [Candle],
        period: Int,
        endOffset: Int,
        value: (Candle) -> Double
    ) -> Double? {
        guard let range = range(candles, period: period, endOffset: endOffset) else { return nil }
        return range.reduce(0.0) { $0 + value(candles[$1]) } / Double(period)
    }

    private static func range(
        _ candles: [Candle],
        period: Int,
        endOffset: Int
    ) -> ClosedRange<Int>? {
        guard period > 0, let endIndex = endingIndex(candles, endOffset: endOffset) else { return nil }
        let startIndex = endIndex - period + 1
        guard startIndex >= 0 else { return nil }
        return startIndex...endIndex
    }

    private static func endingIndex(_ candles: [Candle], endOffset: Int) -> Int? {
        let index = candles.count - 1 - endOffset
        return index >= 0 ? index : nil
    }

    private static func decimalDouble(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
