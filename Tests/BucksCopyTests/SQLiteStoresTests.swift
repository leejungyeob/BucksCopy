import XCTest
@testable import BucksCopy

final class SQLiteStoresTests: XCTestCase {
    func testCandleRepositoryUpsertsBySymbolTimeframeAndOpenTime() throws {
        let path = try temporaryDatabasePath()
        let repository = try SQLiteCandleRepository(path: path)
        let symbol = FuturesSymbol("BTCUSDT")
        let openTime = Date(timeIntervalSince1970: 1_700_000_100)
        let original = Candle(
            productType: .usdtFutures,
            symbol: symbol,
            timeframe: .fifteenMinutes,
            openTime: openTime,
            open: 10,
            high: 12,
            low: 9,
            close: 11,
            volume: 100,
            isClosed: true
        )
        let updated = Candle(
            productType: .usdtFutures,
            symbol: symbol,
            timeframe: .fifteenMinutes,
            openTime: openTime,
            open: 10,
            high: 14,
            low: 8,
            close: 13,
            volume: 200,
            isClosed: true
        )

        try repository.upsertCandles([original, updated])
        let candles = try repository.loadCandles(symbol: symbol, timeframe: .fifteenMinutes, limit: 10)

        XCTAssertEqual(candles.count, 1)
        XCTAssertEqual(candles.first?.high, 14)
        XCTAssertEqual(candles.first?.volume, 200)
    }

    func testCandleRepositoryLoadsBitgetOffsetTwelveHourAndDailyCandles() throws {
        let path = try temporaryDatabasePath()
        let repository = try SQLiteCandleRepository(path: path)
        let symbol = FuturesSymbol("BTCUSDT")
        let twelveHourCandle = makeCandle(
            symbol: symbol,
            timeframe: .twelveHours,
            openTime: Date(timeIntervalSince1970: 1_778_558_400)
        )
        let dailyCandle = makeCandle(
            symbol: symbol,
            timeframe: .oneDay,
            openTime: Date(timeIntervalSince1970: 1_778_428_800)
        )

        try repository.upsertCandles([twelveHourCandle, dailyCandle])

        XCTAssertEqual(
            try repository.loadCandles(symbol: symbol, timeframe: .twelveHours, limit: 10),
            [twelveHourCandle]
        )
        XCTAssertEqual(
            try repository.loadCandles(symbol: symbol, timeframe: .oneDay, limit: 10),
            [dailyCandle]
        )
    }

    func testCandleRepositoryFiltersUnalignedDemoCandleTimes() throws {
        let path = try temporaryDatabasePath()
        let repository = try SQLiteCandleRepository(path: path)
        let symbol = FuturesSymbol("BTCUSDT")
        let unalignedCandle = makeCandle(
            symbol: symbol,
            timeframe: .fifteenMinutes,
            openTime: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try repository.upsertCandles([unalignedCandle])

        XCTAssertEqual(
            try repository.loadCandles(symbol: symbol, timeframe: .fifteenMinutes, limit: 10),
            []
        )
    }

    func testCandleRepositoryCanLoadAllCandlesWithoutDisplayLimit() throws {
        let path = try temporaryDatabasePath()
        let repository = try SQLiteCandleRepository(path: path)
        let symbol = FuturesSymbol("BTCUSDT")
        let candles = (0..<12).map { index in
            makeCandle(
                symbol: symbol,
                timeframe: .fifteenMinutes,
                openTime: Date(timeIntervalSince1970: TimeInterval(index * 900))
            )
        }

        try repository.upsertCandles(candles)

        XCTAssertEqual(
            try repository.loadCandles(symbol: symbol, timeframe: .fifteenMinutes, limit: 5).count,
            5
        )
        XCTAssertEqual(
            try repository.loadAllCandles(symbol: symbol, timeframe: .fifteenMinutes).count,
            12
        )
    }

    func testCandleRepositoryPersistsHistoricalSyncState() throws {
        let path = try temporaryDatabasePath()
        let repository = try SQLiteCandleRepository(path: path)
        let symbol = FuturesSymbol("BTCUSDT")
        let oldest = Date(timeIntervalSince1970: 900)
        let state = CandleHistorySyncState(
            productType: .usdtFutures,
            symbol: symbol,
            timeframe: .fifteenMinutes,
            isComplete: true,
            oldestOpenTime: oldest,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        try repository.saveHistorySyncState(state)
        let loadedState = try repository.loadHistorySyncState(
            symbol: symbol,
            timeframe: .fifteenMinutes
        )

        XCTAssertEqual(loadedState, state)
    }

    func testTradeLogStorePersistsAcrossReopen() throws {
        let path = try temporaryDatabasePath()
        let firstStore = try SQLiteTradeEventLogStore(path: path)
        let log = TradeEventLog(
            timestamp: Date(timeIntervalSince1970: 100),
            category: .bot,
            symbol: FuturesSymbol("ETHUSDT"),
            message: "Live bot evaluated with no signal.",
            metadata: TradeLogMetadata(
                title: "ETHUSDT 15m 매수 진입",
                subtitle: "fixture",
                tags: [
                    TradeLogTag(label: "LIVE", tone: .success),
                    TradeLogTag(label: "15m", tone: .accent)
                ],
                details: [
                    TradeLogDetail(label: "진입가", value: "100", tone: .accent),
                    TradeLogDetail(label: "손절가", value: "95", tone: .danger)
                ]
            )
        )

        try firstStore.append(log)

        let reopenedStore = try SQLiteTradeEventLogStore(path: path)
        let logs = try reopenedStore.loadRecent(limit: 10)

        XCTAssertEqual(logs, [log])
    }

    func testTradeLogStoreMigratesLegacyRowsWithoutMetadataColumn() throws {
        let path = try temporaryDatabasePath()
        let database = try SQLiteDatabase(path: path)
        try database.execute(
            """
            CREATE TABLE trade_event_logs (
                id TEXT PRIMARY KEY NOT NULL,
                timestamp REAL NOT NULL,
                category TEXT NOT NULL,
                severity TEXT NOT NULL,
                symbol TEXT,
                message TEXT NOT NULL
            );
            INSERT INTO trade_event_logs
            (id, timestamp, category, severity, symbol, message)
            VALUES ('00000000-0000-0000-0000-000000000123', 100, 'bot', 'info', 'BTCUSDT', 'legacy');
            """
        )

        let store = try SQLiteTradeEventLogStore(path: path)
        let logs = try store.loadRecent(limit: 10)

        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.message, "legacy")
        XCTAssertNil(logs.first?.metadata)
    }

    func testTradeLogStoreSerializesConcurrentAppendAndLoad() throws {
        let path = try temporaryDatabasePath()
        let store = try SQLiteTradeEventLogStore(path: path)
        let queue = DispatchQueue(label: "BucksCopy.SQLiteStoresTests.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var errors: [Error] = []

        for index in 0..<80 {
            group.enter()
            queue.async {
                defer { group.leave() }

                do {
                    try store.append(TradeEventLog(
                        timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                        category: .bot,
                        symbol: FuturesSymbol("BTCUSDT"),
                        message: "Concurrent log \(index)"
                    ))
                    _ = try store.loadRecent(limit: 10)
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(try store.loadRecent(limit: 100).count, 80)
    }

    func testSQLiteDatabaseErrorDescriptionKeepsUnderlyingMessage() {
        XCTAssertEqual(
            String(describing: SQLiteDatabaseError.prepareFailed("no such table: candles")),
            "prepare failed: no such table: candles"
        )
    }

    private func temporaryDatabasePath() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        return url.path
    }

    private func makeCandle(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        openTime: Date
    ) -> Candle {
        Candle(
            productType: .usdtFutures,
            symbol: symbol,
            timeframe: timeframe,
            openTime: openTime,
            open: 10,
            high: 12,
            low: 9,
            close: 11,
            volume: 100,
            isClosed: true
        )
    }
}
