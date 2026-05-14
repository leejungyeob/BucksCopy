import XCTest
@testable import BucksCopy

final class ChartIndicatorTests: XCTestCase {
    func testSimpleMovingAverageUsesClosePrices() {
        let candles = [
            makeIndicatorCandle(index: 0, close: 10, volume: 1),
            makeIndicatorCandle(index: 1, close: 20, volume: 1),
            makeIndicatorCandle(index: 2, close: 30, volume: 1),
            makeIndicatorCandle(index: 3, close: 50, volume: 1)
        ]

        let series = ChartIndicatorCalculator.simpleMovingAverage(period: 3, candles: candles)

        XCTAssertEqual(series.kind, .simpleMovingAverage(period: 3))
        XCTAssertEqual(series.points.map(\.candleIndex), [2, 3])
        XCTAssertEqual(NSDecimalNumber(decimal: series.points[0].value).doubleValue, 20, accuracy: 0.0001)
        XCTAssertEqual(NSDecimalNumber(decimal: series.points[1].value).doubleValue, 33.3333, accuracy: 0.0001)
    }

    func testVolumeWeightedMovingAverageWeightsCloseByVolume() {
        let candles = [
            makeIndicatorCandle(index: 0, close: 10, volume: 1),
            makeIndicatorCandle(index: 1, close: 20, volume: 3),
            makeIndicatorCandle(index: 2, close: 40, volume: 1)
        ]

        let series = ChartIndicatorCalculator.volumeWeightedMovingAverage(period: 3, candles: candles)

        XCTAssertEqual(series.kind, .volumeWeightedMovingAverage(period: 3))
        XCTAssertEqual(series.points, [
            ChartIndicatorPoint(candleIndex: 2, value: 22)
        ])
    }

    func testIndicatorCalculatorWarmsUpBeforeVisibleRange() {
        let candles = (0..<6).map { index in
            makeIndicatorCandle(index: index, close: Decimal(index + 1), volume: 1)
        }

        let series = ChartIndicatorCalculator.simpleMovingAverage(
            period: 3,
            candles: candles,
            visibleRange: 4..<6
        )

        XCTAssertEqual(series.points, [
            ChartIndicatorPoint(candleIndex: 4, value: 4),
            ChartIndicatorPoint(candleIndex: 5, value: 5)
        ])
    }
}

private func makeIndicatorCandle(index: Int, close: Decimal, volume: Decimal) -> Candle {
    Candle(
        productType: .usdtFutures,
        symbol: FuturesSymbol("BTCUSDT"),
        timeframe: .oneDay,
        openTime: Date(timeIntervalSince1970: TimeInterval(index * 86_400)),
        open: close,
        high: close,
        low: close,
        close: close,
        volume: volume,
        isClosed: true
    )
}
