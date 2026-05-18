import Foundation

final class BitgetCandleBackfillRepository: CandleBackfillRepository {
    private let client: BitgetRESTClient

    init(client: BitgetRESTClient) {
        self.client = client
    }

    func fetchCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) async throws -> [Candle] {
        let receivedAt = Date()
        let rows: [BitgetCandleRow] = try await client.sendPublicGET(
            path: "/api/v2/mix/market/candles",
            queryItems: [
                URLQueryItem(name: "granularity", value: timeframe.bitgetGranularity),
                URLQueryItem(name: "limit", value: String(min(max(limit, 1), 1000))),
                URLQueryItem(name: "productType", value: ProductType.usdtFutures.rawValue),
                URLQueryItem(name: "symbol", value: symbol.rawValue)
            ]
        )

        return rows.compactMap { row in
            row.domain(symbol: symbol, timeframe: timeframe, receivedAt: receivedAt)
        }
        .sorted { $0.openTime < $1.openTime }
    }

    func fetchHistoricalCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        endingBefore endTime: Date,
        limit: Int
    ) async throws -> [Candle] {
        let receivedAt = Date()
        let queryLimit = min(max(limit, 1), 200)
        let maximumHistoryWindow: TimeInterval = 90 * 24 * 60 * 60
        let requestedWindow = timeframe.duration * Double(queryLimit)
        let startTime = endTime.addingTimeInterval(-min(requestedWindow, maximumHistoryWindow))
        let rows: [BitgetCandleRow] = try await client.sendPublicGET(
            path: "/api/v2/mix/market/history-candles",
            queryItems: [
                URLQueryItem(name: "endTime", value: String(Int(endTime.timeIntervalSince1970 * 1000))),
                URLQueryItem(name: "granularity", value: timeframe.bitgetGranularity),
                URLQueryItem(name: "limit", value: String(queryLimit)),
                URLQueryItem(name: "productType", value: ProductType.usdtFutures.rawValue),
                URLQueryItem(name: "startTime", value: String(Int(startTime.timeIntervalSince1970 * 1000))),
                URLQueryItem(name: "symbol", value: symbol.rawValue)
            ]
        )

        return rows.compactMap { row in
            row.domain(symbol: symbol, timeframe: timeframe, receivedAt: receivedAt)
        }
        .sorted { $0.openTime < $1.openTime }
    }
}

struct BitgetCandleRow: Decodable, Equatable {
    let values: [String]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [String] = []
        while !container.isAtEnd {
            values.append(try container.decode(String.self))
        }
        self.values = values
    }

    init(values: [String]) {
        self.values = values
    }

    func domain(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        isClosed: Bool = true
    ) -> Candle? {
        domain(symbol: symbol, timeframe: timeframe, isClosed: isClosed, receivedAt: nil)
    }

    func domain(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        receivedAt: Date
    ) -> Candle? {
        domain(symbol: symbol, timeframe: timeframe, isClosed: nil, receivedAt: receivedAt)
    }

    private func domain(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        isClosed explicitClosedState: Bool?,
        receivedAt: Date?
    ) -> Candle? {
        guard values.count >= 6,
              let milliseconds = Double(values[0]) else {
            return nil
        }
        let openTime = Date(timeIntervalSince1970: milliseconds / 1000)
        let isClosed = explicitClosedState ?? Self.isClosed(
            openTime: openTime,
            timeframe: timeframe,
            receivedAt: receivedAt
        )

        return Candle(
            productType: .usdtFutures,
            symbol: symbol,
            timeframe: timeframe,
            openTime: openTime,
            open: DecimalText.parse(values[1]),
            high: DecimalText.parse(values[2]),
            low: DecimalText.parse(values[3]),
            close: DecimalText.parse(values[4]),
            volume: DecimalText.parse(values[5]),
            isClosed: isClosed
        )
    }

    private static func isClosed(
        openTime: Date,
        timeframe: CandleTimeframe,
        receivedAt: Date?
    ) -> Bool {
        guard let receivedAt else { return true }
        return openTime.addingTimeInterval(timeframe.duration) <= receivedAt
    }
}
