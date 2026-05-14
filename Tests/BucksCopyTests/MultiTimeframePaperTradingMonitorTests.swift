import XCTest
@testable import BucksCopy

final class MultiTimeframePaperTradingMonitorTests: XCTestCase {
    func testEvaluatesRecommendedStrategiesAcrossAllTimeframesAndSkipsDuplicateCandle() async throws {
        let symbol = FuturesSymbol("BTCUSDT")
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let runner = PaperTradingRunner(
            strategyRegistry: registry,
            logStore: logStore,
            confirmationEngine: passingConfirmationEngine(),
            clock: FixedClock(now: Date(timeIntervalSince1970: 10_000))
        )
        let monitor = MultiTimeframePaperTradingMonitor(
            candleRepository: candleRepository,
            candleBackfillRepository: nil,
            paperRunner: runner,
            strategyRegistry: registry
        )

        try candleRepository.upsertCandles(donchianBreakoutCandles(
            symbol: symbol,
            timeframe: .fourHours,
            startOffset: 100
        ))

        let firstRun = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2]
        )
        let secondRun = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2]
        )

        XCTAssertTrue(firstRun.failures.isEmpty)
        XCTAssertEqual(firstRun.signalCount, 1)
        XCTAssertTrue(firstRun.evaluations.contains {
            $0.symbol == symbol &&
                $0.timeframe == .fourHours &&
                $0.strategyID == DonchianChannelBreakoutStrategy.identifier
        })
        XCTAssertTrue(secondRun.evaluations.isEmpty)

        let logs = try logStore.loadRecent(limit: 10)
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].message.contains(DonchianChannelBreakoutStrategy.identifier))
        XCTAssertTrue(logs[0].message.contains("4H"))
    }

    func testBackfillsRemoteCandlesBeforeMonitoringTimeframe() async throws {
        let symbol = FuturesSymbol("BTCUSDT")
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let backfillRepository = MonitorBackfillRepository(candles: donchianBreakoutCandles(
            symbol: symbol,
            timeframe: .fourHours,
            startOffset: 200
        ))
        let monitor = MultiTimeframePaperTradingMonitor(
            candleRepository: candleRepository,
            candleBackfillRepository: backfillRepository,
            paperRunner: PaperTradingRunner(
                strategyRegistry: registry,
                logStore: logStore,
                confirmationEngine: passingConfirmationEngine()
            ),
            strategyRegistry: registry
        )

        let result = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2]
        )

        XCTAssertEqual(result.signalCount, 1)
        XCTAssertEqual(backfillRepository.requestedTimeframes, Set(CandleTimeframe.allCases))
        let storedCandles = try candleRepository.loadCandles(
            symbol: symbol,
            timeframe: .fourHours,
            limit: 10
        )
        XCTAssertEqual(storedCandles.count, 10)
    }
}

private struct MonitorEvidenceRule: SignalConfirmationRule {
    let id: String
    let group: SignalEvidenceGroup
    let score: Decimal

    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence? {
        SignalEvidence(id: id, group: group, score: score, reason: id)
    }
}

private func passingConfirmationEngine() -> SignalConfirmationEngine {
    SignalConfirmationEngine(rules: [
        MonitorEvidenceRule(id: "trend", group: .trend, score: 20),
        MonitorEvidenceRule(id: "momentum", group: .momentum, score: 5)
    ])
}

private final class MonitorBackfillRepository: CandleBackfillRepository {
    let candles: [Candle]
    private(set) var requestedTimeframes: Set<CandleTimeframe> = []

    init(candles: [Candle]) {
        self.candles = candles
    }

    func fetchCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) async throws -> [Candle] {
        requestedTimeframes.insert(timeframe)
        guard timeframe == candles.first?.timeframe else { return [] }
        return candles
    }

    func fetchHistoricalCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        endingBefore endTime: Date,
        limit: Int
    ) async throws -> [Candle] {
        []
    }
}

private func donchianBreakoutCandles(
    symbol: FuturesSymbol,
    timeframe: CandleTimeframe,
    startOffset: Int
) -> [Candle] {
    (0..<34).map { offset in
        monitorCandle(
            symbol: symbol,
            timeframe: timeframe,
            offset: startOffset + offset,
            open: 100,
            high: 101,
            low: 99,
            close: 100
        )
    } + [
        monitorCandle(
            symbol: symbol,
            timeframe: timeframe,
            offset: startOffset + 34,
            open: 100,
            high: 106,
            low: 99,
            close: 105
        )
    ]
}

private func monitorCandle(
    symbol: FuturesSymbol,
    timeframe: CandleTimeframe,
    offset: Int,
    open: Decimal,
    high: Decimal,
    low: Decimal,
    close: Decimal
) -> Candle {
    Candle(
        productType: .usdtFutures,
        symbol: symbol,
        timeframe: timeframe,
        openTime: Date(timeIntervalSince1970: TimeInterval(offset) * timeframe.duration),
        open: open,
        high: high,
        low: low,
        close: close,
        volume: 1_000,
        isClosed: true
    )
}
