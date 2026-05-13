import Foundation

final class SQLiteCandleRepository: CandleRepository, CandleHistoryStateStore {
    private let database: SQLiteDatabase
    private let queue = DispatchQueue(label: "BucksCopy.SQLiteCandleRepository")

    init(database: SQLiteDatabase) throws {
        self.database = database
        try createTableIfNeeded()
    }

    convenience init(path: String) throws {
        try self.init(database: SQLiteDatabase(path: path))
    }

    func loadCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) throws -> [Candle] {
        try queue.sync {
            let statement = try database.prepare(
                """
                SELECT product_type, symbol, timeframe, open_time, open, high, low, close, volume, is_closed
                FROM candles
                WHERE product_type = ? AND symbol = ? AND timeframe = ?
                ORDER BY open_time DESC
                LIMIT ?;
                """
            )
            try statement.bind(ProductType.usdtFutures.rawValue, at: 1)
            try statement.bind(symbol.rawValue, at: 2)
            try statement.bind(timeframe.rawValue, at: 3)
            let fetchLimit = max(limit * 5, limit)
            try statement.bind(fetchLimit, at: 4)

            var candles: [Candle] = []
            while try statement.step() {
                guard
                    let productText = statement.string(at: 0),
                    let productType = ProductType(rawValue: productText),
                    let symbolText = statement.string(at: 1),
                    let timeframeText = statement.string(at: 2),
                    let timeframe = CandleTimeframe(rawValue: timeframeText)
                else {
                    continue
                }

                let openTime = Date(timeIntervalSince1970: statement.double(at: 3))
                guard Self.isAlignedExchangeOpenTime(openTime, timeframe: timeframe) else {
                    continue
                }

                candles.append(Candle(
                    productType: productType,
                    symbol: FuturesSymbol(symbolText),
                    timeframe: timeframe,
                    openTime: openTime,
                    open: DecimalText.parse(statement.string(at: 4)),
                    high: DecimalText.parse(statement.string(at: 5)),
                    low: DecimalText.parse(statement.string(at: 6)),
                    close: DecimalText.parse(statement.string(at: 7)),
                    volume: DecimalText.parse(statement.string(at: 8)),
                    isClosed: statement.int(at: 9) == 1
                ))
            }

            return Array(candles.sorted { $0.openTime < $1.openTime }.suffix(limit))
        }
    }

    func loadOldestCandleOpenTime(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) throws -> Date? {
        try queue.sync {
            let statement = try database.prepare(
                """
                SELECT open_time
                FROM candles
                WHERE product_type = ? AND symbol = ? AND timeframe = ?
                ORDER BY open_time ASC
                LIMIT 1;
                """
            )
            try statement.bind(ProductType.usdtFutures.rawValue, at: 1)
            try statement.bind(symbol.rawValue, at: 2)
            try statement.bind(timeframe.rawValue, at: 3)

            guard try statement.step() else {
                return nil
            }
            return Date(timeIntervalSince1970: statement.double(at: 0))
        }
    }

    func upsertCandles(_ candles: [Candle]) throws {
        try queue.sync {
            let statement = try database.prepare(
                """
                INSERT INTO candles
                (product_type, symbol, timeframe, open_time, open, high, low, close, volume, is_closed)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(product_type, symbol, timeframe, open_time)
                DO UPDATE SET
                  open = excluded.open,
                  high = excluded.high,
                  low = excluded.low,
                  close = excluded.close,
                  volume = excluded.volume,
                  is_closed = excluded.is_closed;
                """
            )

            for candle in candles {
                try statement.bind(candle.productType.rawValue, at: 1)
                try statement.bind(candle.symbol.rawValue, at: 2)
                try statement.bind(candle.timeframe.rawValue, at: 3)
                try statement.bind(candle.openTime.timeIntervalSince1970, at: 4)
                try statement.bind(candle.open.description, at: 5)
                try statement.bind(candle.high.description, at: 6)
                try statement.bind(candle.low.description, at: 7)
                try statement.bind(candle.close.description, at: 8)
                try statement.bind(candle.volume.description, at: 9)
                try statement.bind(candle.isClosed ? 1 : 0, at: 10)
                _ = try statement.step()
                statement.reset()
            }
        }
    }

    func loadHistorySyncState(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) throws -> CandleHistorySyncState? {
        try queue.sync {
            let statement = try database.prepare(
                """
                SELECT product_type, symbol, timeframe, is_complete, oldest_open_time, updated_at
                FROM candle_history_sync
                WHERE product_type = ? AND symbol = ? AND timeframe = ?
                LIMIT 1;
                """
            )
            try statement.bind(ProductType.usdtFutures.rawValue, at: 1)
            try statement.bind(symbol.rawValue, at: 2)
            try statement.bind(timeframe.rawValue, at: 3)

            guard try statement.step(),
                  let productText = statement.string(at: 0),
                  let productType = ProductType(rawValue: productText),
                  let symbolText = statement.string(at: 1),
                  let timeframeText = statement.string(at: 2),
                  let timeframe = CandleTimeframe(rawValue: timeframeText) else {
                return nil
            }

            let oldestOpenTimeSeconds = statement.double(at: 4)
            return CandleHistorySyncState(
                productType: productType,
                symbol: FuturesSymbol(symbolText),
                timeframe: timeframe,
                isComplete: statement.int(at: 3) == 1,
                oldestOpenTime: oldestOpenTimeSeconds > 0
                    ? Date(timeIntervalSince1970: oldestOpenTimeSeconds)
                    : nil,
                updatedAt: Date(timeIntervalSince1970: statement.double(at: 5))
            )
        }
    }

    func saveHistorySyncState(_ state: CandleHistorySyncState) throws {
        try queue.sync {
            let statement = try database.prepare(
                """
                INSERT INTO candle_history_sync
                (product_type, symbol, timeframe, is_complete, oldest_open_time, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(product_type, symbol, timeframe)
                DO UPDATE SET
                  is_complete = excluded.is_complete,
                  oldest_open_time = excluded.oldest_open_time,
                  updated_at = excluded.updated_at;
                """
            )
            try statement.bind(state.productType.rawValue, at: 1)
            try statement.bind(state.symbol.rawValue, at: 2)
            try statement.bind(state.timeframe.rawValue, at: 3)
            try statement.bind(state.isComplete ? 1 : 0, at: 4)
            try statement.bind(state.oldestOpenTime?.timeIntervalSince1970 ?? 0, at: 5)
            try statement.bind(state.updatedAt.timeIntervalSince1970, at: 6)
            _ = try statement.step()
        }
    }

    private func createTableIfNeeded() throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS candles (
                product_type TEXT NOT NULL,
                symbol TEXT NOT NULL,
                timeframe TEXT NOT NULL,
                open_time REAL NOT NULL,
                open TEXT NOT NULL,
                high TEXT NOT NULL,
                low TEXT NOT NULL,
                close TEXT NOT NULL,
                volume TEXT NOT NULL,
                is_closed INTEGER NOT NULL,
                PRIMARY KEY(product_type, symbol, timeframe, open_time)
            );
            CREATE INDEX IF NOT EXISTS idx_candles_symbol_timeframe
            ON candles(product_type, symbol, timeframe, open_time DESC);

            CREATE TABLE IF NOT EXISTS candle_history_sync (
                product_type TEXT NOT NULL,
                symbol TEXT NOT NULL,
                timeframe TEXT NOT NULL,
                is_complete INTEGER NOT NULL,
                oldest_open_time REAL NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY(product_type, symbol, timeframe)
            );
            """
        )
    }

    private static func isAlignedExchangeOpenTime(_ openTime: Date, timeframe: CandleTimeframe) -> Bool {
        let seconds = openTime.timeIntervalSince1970
        guard seconds.rounded() == seconds else { return false }
        let remainder = seconds.truncatingRemainder(dividingBy: timeframe.duration)
        return Self.validOpenTimeRemainders(for: timeframe).contains { validRemainder in
            abs(remainder - validRemainder) < 0.001 ||
                abs(remainder - validRemainder - timeframe.duration) < 0.001
        }
    }

    private static func validOpenTimeRemainders(for timeframe: CandleTimeframe) -> [TimeInterval] {
        switch timeframe {
        case .fifteenMinutes, .oneHour, .fourHours:
            return [0]
        case .twelveHours:
            return [0, 4 * 60 * 60]
        case .oneDay:
            return [0, 16 * 60 * 60]
        }
    }
}
