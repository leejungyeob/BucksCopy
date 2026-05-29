import XCTest
@testable import BucksCopy

final class MultiTimeframeLiveTradingMonitorTests: XCTestCase {
    func testEvaluatesRecommendedStrategiesAcrossConfiguredTimeframesAndSkipsDuplicateCandle() async throws {
        let symbol = FuturesSymbol("SOLUSDT")
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let runner = TradingSignalEvaluator(
            strategyRegistry: registry,
            logStore: logStore,
            confirmationEngine: passingConfirmationEngine(),
            clock: FixedClock(now: Date(timeIntervalSince1970: 10_000))
        )
        let monitor = MultiTimeframeLiveTradingMonitor(
            candleRepository: candleRepository,
            candleBackfillRepository: nil,
            signalEvaluator: runner,
            liveExecutor: monitorLiveExecutor(logStore: logStore),
            strategyRegistry: registry,
            monitoredTimeframes: [.fourHours]
        )

        try candleRepository.upsertCandles(donchianBreakoutCandles(
            symbol: symbol,
            timeframe: .fourHours,
            startOffset: 100
        ))

        let firstRun = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2],
            accountEquity: 1_000,
            contractSpecs: [monitorContractSpec(symbol: symbol)]
        )
        let secondRun = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2],
            accountEquity: 1_000,
            contractSpecs: [monitorContractSpec(symbol: symbol)]
        )

        XCTAssertTrue(firstRun.failures.isEmpty)
        XCTAssertEqual(firstRun.signalCount, 1)
        XCTAssertTrue(firstRun.evaluations.contains {
            $0.symbol == symbol &&
                $0.timeframe == .fourHours &&
                $0.strategyID == DonchianChannelBreakoutStrategy.identifier
        })
        XCTAssertEqual(secondRun.signalCount, 0)

        let logs = try logStore.loadRecent(limit: 10)
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].message.contains(DonchianChannelBreakoutStrategy.identifier))
        XCTAssertTrue(logs[0].message.contains("4H"))
    }

    func testBackfillsRemoteCandlesBeforeMonitoringTimeframe() async throws {
        let symbol = FuturesSymbol("SOLUSDT")
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let backfillRepository = MonitorBackfillRepository(candles: donchianBreakoutCandles(
            symbol: symbol,
            timeframe: .fourHours,
            startOffset: 200
        ))
        let monitor = MultiTimeframeLiveTradingMonitor(
            candleRepository: candleRepository,
            candleBackfillRepository: backfillRepository,
            signalEvaluator: TradingSignalEvaluator(
                strategyRegistry: registry,
                logStore: logStore,
                confirmationEngine: passingConfirmationEngine()
            ),
            liveExecutor: monitorLiveExecutor(logStore: logStore),
            strategyRegistry: registry,
            monitoredTimeframes: [.fourHours]
        )

        let result = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2],
            accountEquity: 1_000,
            contractSpecs: [monitorContractSpec(symbol: symbol)]
        )

        XCTAssertEqual(result.signalCount, 1)
        XCTAssertEqual(backfillRepository.requestedTimeframes, Set([.fourHours]))
        let storedCandles = try candleRepository.loadCandles(
            symbol: symbol,
            timeframe: .fourHours,
            limit: 10
        )
        XCTAssertEqual(storedCandles.count, 10)
    }

    func testUsesFreshLocalCandlesWhenRemoteRefreshTimesOut() async throws {
        let symbol = FuturesSymbol("SOLUSDT")
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let localCandles = donchianBreakoutCandles(
            symbol: symbol,
            timeframe: .fourHours,
            startOffset: 200
        )
        try candleRepository.upsertCandles(localCandles)

        let monitor = MultiTimeframeLiveTradingMonitor(
            candleRepository: candleRepository,
            candleBackfillRepository: FailingMonitorBackfillRepository(),
            signalEvaluator: TradingSignalEvaluator(
                strategyRegistry: registry,
                logStore: logStore,
                confirmationEngine: passingConfirmationEngine()
            ),
            liveExecutor: monitorLiveExecutor(logStore: logStore),
            strategyRegistry: registry,
            clock: FixedClock(now: try XCTUnwrap(localCandles.last?.openTime).addingTimeInterval(
                CandleTimeframe.fourHours.duration + 60
            )),
            remoteRefreshAttempts: 1,
            remoteRefreshRetryDelayNanoseconds: 0,
            monitoredTimeframes: [.fourHours]
        )

        let result = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2],
            accountEquity: 1_000,
            contractSpecs: [monitorContractSpec(symbol: symbol)]
        )

        XCTAssertFalse(result.failures.contains { $0.timeframe == .fourHours })
        XCTAssertEqual(result.signalCount, 1)
    }

    func testRetriesRemoteCandleTimeoutBeforeEvaluating() async throws {
        let symbol = FuturesSymbol("SOLUSDT")
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let backfillRepository = FlakyMonitorBackfillRepository(
            candles: donchianBreakoutCandles(
                symbol: symbol,
                timeframe: .fourHours,
                startOffset: 200
            ),
            failuresBeforeSuccess: 2
        )
        let monitor = MultiTimeframeLiveTradingMonitor(
            candleRepository: candleRepository,
            candleBackfillRepository: backfillRepository,
            signalEvaluator: TradingSignalEvaluator(
                strategyRegistry: registry,
                logStore: logStore,
                confirmationEngine: passingConfirmationEngine()
            ),
            liveExecutor: monitorLiveExecutor(logStore: logStore),
            strategyRegistry: registry,
            remoteRefreshAttempts: 3,
            remoteRefreshRetryDelayNanoseconds: 0,
            monitoredTimeframes: [.fourHours]
        )

        let result = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2],
            accountEquity: 1_000,
            contractSpecs: [monitorContractSpec(symbol: symbol)]
        )

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.signalCount, 1)
        XCTAssertEqual(backfillRepository.attempts[.fourHours], 3)
    }

    func testIgnoresFormingCandleEvenWhenItCouldGenerateLiveSignal() async throws {
        let symbol = FuturesSymbol("SOLUSDT")
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let candles = donchianBreakoutCandles(
            symbol: symbol,
            timeframe: .fourHours,
            startOffset: 200
        )
        let latestSignalCandle = try XCTUnwrap(candles.last)
        try candleRepository.upsertCandles(candles)

        let monitor = MultiTimeframeLiveTradingMonitor(
            candleRepository: candleRepository,
            candleBackfillRepository: nil,
            signalEvaluator: TradingSignalEvaluator(
                strategyRegistry: registry,
                logStore: logStore,
                confirmationEngine: passingConfirmationEngine()
            ),
            liveExecutor: monitorLiveExecutor(logStore: logStore),
            strategyRegistry: registry,
            clock: FixedClock(now: latestSignalCandle.openTime.addingTimeInterval(
                CandleTimeframe.fourHours.duration - 60
            )),
            monitoredTimeframes: [.fourHours]
        )

        let result = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2],
            accountEquity: 1_000,
            contractSpecs: [monitorContractSpec(symbol: symbol)]
        )

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.signalCount, 0)
        XCTAssertFalse(result.evaluations.contains {
            $0.candleOpenTime == latestSignalCandle.openTime
        })
    }

    func testDoesNotReevaluateFormingCandleAfterNoSignalUpdate() async throws {
        let symbol = FuturesSymbol("SOLUSDT")
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let noSignalCandles = donchianNoSignalCandles(
            symbol: symbol,
            timeframe: .fourHours,
            startOffset: 300,
            isLatestClosed: false
        )
        let latestOpenTime = try XCTUnwrap(noSignalCandles.last?.openTime)
        let monitor = MultiTimeframeLiveTradingMonitor(
            candleRepository: candleRepository,
            candleBackfillRepository: nil,
            signalEvaluator: TradingSignalEvaluator(
                strategyRegistry: registry,
                logStore: logStore,
                confirmationEngine: passingConfirmationEngine()
            ),
            liveExecutor: monitorLiveExecutor(logStore: logStore),
            strategyRegistry: registry,
            clock: FixedClock(now: latestOpenTime.addingTimeInterval(60)),
            monitoredTimeframes: [.fourHours]
        )

        try candleRepository.upsertCandles(noSignalCandles)
        let noSignalRun = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2],
            accountEquity: 1_000,
            contractSpecs: [monitorContractSpec(symbol: symbol)]
        )

        try candleRepository.upsertCandles(donchianBreakoutCandles(
            symbol: symbol,
            timeframe: .fourHours,
            startOffset: 300,
            isLatestClosed: false
        ))
        let updatedSignalRun = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2],
            accountEquity: 1_000,
            contractSpecs: [monitorContractSpec(symbol: symbol)]
        )

        XCTAssertTrue(noSignalRun.failures.isEmpty)
        XCTAssertEqual(noSignalRun.signalCount, 0)
        XCTAssertFalse(noSignalRun.evaluations.contains {
            $0.candleOpenTime == latestOpenTime
        })
        XCTAssertEqual(updatedSignalRun.signalCount, 0)
        XCTAssertFalse(updatedSignalRun.evaluations.contains {
            $0.candleOpenTime == latestOpenTime
        })
    }

    func testDoesNotSynthesizeHigherTimeframeFormingCandleFromFifteenMinuteFallback() async throws {
        let symbol = FuturesSymbol("SOLUSDT")
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let startOffset = 400
        let formingFourHourOffset = startOffset + 34
        let formingFourHourOpenTime = Date(
            timeIntervalSince1970: TimeInterval(formingFourHourOffset) * CandleTimeframe.fourHours.duration
        )
        let monitor = MultiTimeframeLiveTradingMonitor(
            candleRepository: candleRepository,
            candleBackfillRepository: FailingMonitorBackfillRepository(),
            signalEvaluator: TradingSignalEvaluator(
                strategyRegistry: registry,
                logStore: logStore,
                confirmationEngine: passingConfirmationEngine()
            ),
            liveExecutor: monitorLiveExecutor(logStore: logStore),
            strategyRegistry: registry,
            clock: FixedClock(now: formingFourHourOpenTime.addingTimeInterval(60)),
            remoteRefreshAttempts: 1,
            remoteRefreshRetryDelayNanoseconds: 0,
            monitoredTimeframes: [.fourHours]
        )

        try candleRepository.upsertCandles((0..<34).map { offset in
            monitorCandle(
                symbol: symbol,
                timeframe: .fourHours,
                offset: startOffset + offset,
                open: 100,
                high: 101,
                low: 99,
                close: 100
            )
        })
        try candleRepository.upsertCandles([
            monitorCandle(
                symbol: symbol,
                timeframe: .fifteenMinutes,
                offset: formingFourHourOffset * 16,
                open: 100,
                high: 106,
                low: 99,
                close: 105,
                isClosed: false
            )
        ])

        let result = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2],
            accountEquity: 1_000,
            contractSpecs: [monitorContractSpec(symbol: symbol)]
        )

        XCTAssertFalse(result.failures.contains { $0.timeframe == .fourHours })
        XCTAssertEqual(result.signalCount, 0)
        XCTAssertFalse(result.evaluations.contains {
            $0.candleOpenTime == formingFourHourOpenTime
        })
    }

    func testPrimingCurrentClosedCandlesPreventsStartupEntryUntilNextClosedCandle() async throws {
        let symbol = FuturesSymbol("SOLUSDT")
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let monitor = MultiTimeframeLiveTradingMonitor(
            candleRepository: candleRepository,
            candleBackfillRepository: nil,
            signalEvaluator: TradingSignalEvaluator(
                strategyRegistry: registry,
                logStore: logStore,
                confirmationEngine: passingConfirmationEngine()
            ),
            liveExecutor: monitorLiveExecutor(logStore: logStore),
            strategyRegistry: registry,
            monitoredTimeframes: [.fourHours]
        )

        try candleRepository.upsertCandles(donchianBreakoutCandles(
            symbol: symbol,
            timeframe: .fourHours,
            startOffset: 100
        ))

        let priming = await monitor.primeLatestClosedCandles(watchlist: [symbol])
        let startupRun = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2],
            accountEquity: 1_000,
            contractSpecs: [monitorContractSpec(symbol: symbol)]
        )

        try candleRepository.upsertCandles(donchianBreakoutCandles(
            symbol: symbol,
            timeframe: .fourHours,
            startOffset: 200
        ))
        let nextCandleRun = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 2],
            accountEquity: 1_000,
            contractSpecs: [monitorContractSpec(symbol: symbol)]
        )

        XCTAssertEqual(priming.primedCount, 1)
        XCTAssertTrue(startupRun.evaluations.isEmpty)
        XCTAssertEqual(startupRun.executionResult?.didSubmitOrder, false)
        XCTAssertEqual(nextCandleRun.signalCount, 1)
    }

    func testClosesAppManagedPositionWhenMaximumHoldingPeriodExpires() async throws {
        let symbol = FuturesSymbol("BTCUSDT")
        let now = Date(timeIntervalSince1970: 200_000)
        let clock = FixedClock(now: now)
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let client = TestLiveOrderClient()
        let registry = StrategyRegistry(strategies: [BTCFifteenMinuteVacuumPulseStrategy()])
        let executor = LiveTradeExecutor(
            orderPlacer: client,
            leverageSetter: client,
            protectionInstaller: ExchangeProtectionInstaller(
                orderPlacer: client,
                retryPolicy: ExchangeProtectionRetryPolicy(retryDelayNanoseconds: 0)
            ),
            logStore: logStore,
            clock: clock
        )
        let monitor = MultiTimeframeLiveTradingMonitor(
            candleRepository: candleRepository,
            candleBackfillRepository: nil,
            signalEvaluator: TradingSignalEvaluator(
                strategyRegistry: registry,
                logStore: logStore,
                confirmationEngine: passingConfirmationEngine(),
                clock: clock
            ),
            liveExecutor: executor,
            strategyRegistry: registry,
            clock: clock
        )
        try logStore.append(TradeEventLog(
            timestamp: now.addingTimeInterval(-CandleTimeframe.fifteenMinutes.duration * 97),
            category: .liveOrder,
            symbol: symbol,
            message: "Live buy order submitted by \(BTCFifteenMinuteVacuumPulseStrategy.identifier) on 15m.",
            metadata: TradeLogMetadata(
                title: "BTCUSDT 15m 매수 진입",
                tags: [
                    TradeLogTag(label: "LIVE", tone: .success),
                    TradeLogTag(label: "15m", tone: .accent),
                    TradeLogTag(label: "매수", tone: .success),
                    TradeLogTag(label: BTCFifteenMinuteVacuumPulseStrategy.identifier, tone: .neutral)
                ],
                details: [
                    TradeLogDetail(label: "매매전략", value: BTCFifteenMinuteVacuumPulseStrategy.identifier),
                    TradeLogDetail(label: "시간봉", value: "15m")
                ]
            )
        ))

        let result = await monitor.evaluateOnce(
            watchlist: [symbol],
            leverageBySymbol: [symbol: 10],
            openPositions: [monitorPosition(symbol: symbol, side: .long)],
            accountEquity: 1_000,
            contractSpecs: [monitorContractSpec(symbol: symbol)]
        )

        XCTAssertEqual(client.closeRequests.count, 1)
        XCTAssertEqual(client.closeRequests.first?.symbol, symbol)
        XCTAssertEqual(client.closeRequests.first?.holdSide, .long)
        XCTAssertEqual(result.executionResult?.didSubmitOrder, true)
        XCTAssertTrue(result.evaluations.isEmpty)
        let closeLog = try XCTUnwrap(try logStore.loadRecent(limit: 10).first {
            $0.metadata?.title.contains("보유기간 종료") == true
        })
        XCTAssertTrue(closeLog.metadata?.details.contains {
            $0.label == "청산 근거" && $0.value.contains("최대 보유 기간 96봉")
        } ?? false)
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

private func monitorLiveExecutor(logStore: TradeEventLogStore) -> LiveTradeExecutor {
    let client = TestLiveOrderClient()
    return LiveTradeExecutor(
        orderPlacer: client,
        leverageSetter: client,
        protectionInstaller: ExchangeProtectionInstaller(
            orderPlacer: client,
            retryPolicy: ExchangeProtectionRetryPolicy(retryDelayNanoseconds: 0)
        ),
        logStore: logStore
    )
}

private func monitorContractSpec(symbol: FuturesSymbol) -> ContractSpec {
    ContractSpec(
        symbol: symbol,
        baseCoin: symbol.rawValue.replacingOccurrences(of: "USDT", with: ""),
        quoteCoin: "USDT",
        symbolStatus: "normal",
        supportMarginCoins: ["USDT"],
        minTradeNum: Decimal(string: "0.0001")!,
        minTradeUSDT: 5,
        sizeMultiplier: Decimal(string: "0.0001")!,
        pricePlace: 1,
        volumePlace: 4,
        minLeverage: 1,
        maxLeverage: 10
    )
}

private func monitorPosition(
    symbol: FuturesSymbol,
    side: PositionSide
) -> PositionSnapshot {
    PositionSnapshot(
        symbol: symbol,
        side: side,
        total: 1,
        available: 1,
        openPriceAverage: 100,
        markPrice: 101,
        unrealizedProfitLoss: 1,
        leverage: 10,
        marginMode: "isolated",
        positionMode: .hedge,
        liquidationPrice: nil,
        takeProfit: 120,
        stopLoss: 90,
        createdAt: nil,
        updatedAt: nil
    )
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

private final class FailingMonitorBackfillRepository: CandleBackfillRepository {
    func fetchCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) async throws -> [Candle] {
        throw URLError(.timedOut)
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

private final class FlakyMonitorBackfillRepository: CandleBackfillRepository {
    let candles: [Candle]
    let failuresBeforeSuccess: Int
    private(set) var attempts: [CandleTimeframe: Int] = [:]

    init(candles: [Candle], failuresBeforeSuccess: Int) {
        self.candles = candles
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func fetchCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) async throws -> [Candle] {
        attempts[timeframe, default: 0] += 1
        if attempts[timeframe, default: 0] <= failuresBeforeSuccess {
            throw URLError(.timedOut)
        }
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
    startOffset: Int,
    isLatestClosed: Bool = true
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
            close: 105,
            isClosed: isLatestClosed
        )
    ]
}

private func donchianNoSignalCandles(
    symbol: FuturesSymbol,
    timeframe: CandleTimeframe,
    startOffset: Int,
    isLatestClosed: Bool = true
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
            high: 101,
            low: 99,
            close: 100,
            isClosed: isLatestClosed
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
    close: Decimal,
    isClosed: Bool = true
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
        isClosed: isClosed
    )
}
