import Foundation

struct DemoDataSeeder {
    private let candleRepository: CandleRepository

    init(candleRepository: CandleRepository) {
        self.candleRepository = candleRepository
    }

    func seedIfNeeded() throws {
        let symbols = [FuturesSymbol("BTCUSDT"), FuturesSymbol("ETHUSDT")]
        for symbol in symbols {
            for timeframe in CandleTimeframe.allCases {
                let existing = try candleRepository.loadCandles(
                    symbol: symbol,
                    timeframe: timeframe,
                    limit: 1
                )
                if existing.isEmpty {
                    try candleRepository.upsertCandles(Self.makeCandles(
                        symbol: symbol,
                        timeframe: timeframe,
                        count: 140
                    ))
                }
            }
        }
    }

    static func makeCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        count: Int
    ) -> [Candle] {
        let basePrice: Decimal = symbol.rawValue.hasPrefix("ETH") ? 3_000 : 92_000
        let now = Date()
        let endTime = now.addingTimeInterval(-timeframe.duration)

        return (0..<count).map { index in
            let offset = count - index
            let openTime = endTime.addingTimeInterval(-Double(offset) * timeframe.duration)
            let wave = Decimal(Double(index % 17) - 8) * Decimal(string: "0.0015")!
            let drift = Decimal(index) * Decimal(string: "0.0008")!
            let open = basePrice * (1 + wave + drift)
            let close = open * (1 + Decimal(Double((index % 9) - 4)) * Decimal(string: "0.0009")!)
            let high = max(open, close) * Decimal(string: "1.0025")!
            let low = min(open, close) * Decimal(string: "0.9975")!

            return Candle(
                productType: .usdtFutures,
                symbol: symbol,
                timeframe: timeframe,
                openTime: openTime,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: Decimal(1_000 + index * 11),
                isClosed: true
            )
        }
    }
}
