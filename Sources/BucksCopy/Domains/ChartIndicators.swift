import Foundation

enum ChartIndicatorKind: Equatable {
    case simpleMovingAverage(period: Int)
    case volumeWeightedMovingAverage(period: Int)

    var label: String {
        switch self {
        case .simpleMovingAverage(let period):
            return "MA\(period)"
        case .volumeWeightedMovingAverage(let period):
            return "VWMA\(period)"
        }
    }
}

struct ChartIndicatorPoint: Equatable {
    let candleIndex: Int
    let value: Decimal
}

struct ChartIndicatorSeries: Equatable {
    let kind: ChartIndicatorKind
    let points: [ChartIndicatorPoint]
}

enum ChartIndicatorCalculator {
    static func simpleMovingAverage(
        period: Int,
        candles: [Candle],
        visibleRange: Range<Int>? = nil
    ) -> ChartIndicatorSeries {
        guard period > 0, !candles.isEmpty else {
            return ChartIndicatorSeries(kind: .simpleMovingAverage(period: period), points: [])
        }

        let outputRange = normalizedRange(visibleRange, candleCount: candles.count)
        guard !outputRange.isEmpty else {
            return ChartIndicatorSeries(kind: .simpleMovingAverage(period: period), points: [])
        }

        let warmupStart = max(0, outputRange.lowerBound - period + 1)
        var runningSum: Decimal = 0
        var runningCount = 0
        var points: [ChartIndicatorPoint] = []
        points.reserveCapacity(outputRange.count)

        for index in warmupStart..<outputRange.upperBound {
            runningSum += candles[index].close
            runningCount += 1

            let removalIndex = index - period
            if removalIndex >= warmupStart {
                runningSum -= candles[removalIndex].close
                runningCount -= 1
            }

            guard outputRange.contains(index), runningCount == period else { continue }
            points.append(ChartIndicatorPoint(
                candleIndex: index,
                value: runningSum / Decimal(period)
            ))
        }

        return ChartIndicatorSeries(kind: .simpleMovingAverage(period: period), points: points)
    }

    static func volumeWeightedMovingAverage(
        period: Int,
        candles: [Candle],
        visibleRange: Range<Int>? = nil
    ) -> ChartIndicatorSeries {
        guard period > 0, !candles.isEmpty else {
            return ChartIndicatorSeries(kind: .volumeWeightedMovingAverage(period: period), points: [])
        }

        let outputRange = normalizedRange(visibleRange, candleCount: candles.count)
        guard !outputRange.isEmpty else {
            return ChartIndicatorSeries(kind: .volumeWeightedMovingAverage(period: period), points: [])
        }

        let warmupStart = max(0, outputRange.lowerBound - period + 1)
        var runningWeightedClose: Decimal = 0
        var runningVolume: Decimal = 0
        var runningCount = 0
        var points: [ChartIndicatorPoint] = []
        points.reserveCapacity(outputRange.count)

        for index in warmupStart..<outputRange.upperBound {
            let candle = candles[index]
            runningWeightedClose += candle.close * candle.volume
            runningVolume += candle.volume
            runningCount += 1

            let removalIndex = index - period
            if removalIndex >= warmupStart {
                let removed = candles[removalIndex]
                runningWeightedClose -= removed.close * removed.volume
                runningVolume -= removed.volume
                runningCount -= 1
            }

            guard outputRange.contains(index),
                  runningCount == period,
                  runningVolume > 0 else { continue }
            points.append(ChartIndicatorPoint(
                candleIndex: index,
                value: runningWeightedClose / runningVolume
            ))
        }

        return ChartIndicatorSeries(kind: .volumeWeightedMovingAverage(period: period), points: points)
    }

    private static func normalizedRange(_ range: Range<Int>?, candleCount: Int) -> Range<Int> {
        guard let range else { return 0..<candleCount }
        let lowerBound = min(max(range.lowerBound, 0), candleCount)
        let upperBound = min(max(range.upperBound, lowerBound), candleCount)
        return lowerBound..<upperBound
    }
}
