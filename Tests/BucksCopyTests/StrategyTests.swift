import XCTest
@testable import BucksCopy

final class StrategyTests: XCTestCase {
    func testNoopStrategyDoesNotCreateSignal() throws {
        let strategy = NoopStrategy()
        let context = StrategyContext(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .oneHour,
            closedCandles: [],
            generatedAt: Date(timeIntervalSince1970: 100)
        )

        let evaluation = try strategy.evaluate(context, config: .default)

        XCTAssertEqual(evaluation, .noSignal)
    }

    func testDefaultRegistryIncludesResearchedBuiltInStrategies() {
        let ids = Set(StrategyRegistry().definitions.map(\.id))

        XCTAssertTrue(ids.contains(TrendPullbackStrategy.identifier))
        XCTAssertTrue(ids.contains(BollingerRSIReversionStrategy.identifier))
        XCTAssertTrue(ids.contains(VWMAReclaimStrategy.identifier))
        XCTAssertTrue(ids.contains(KeltnerATRPullbackStrategy.identifier))
        XCTAssertTrue(ids.contains(DonchianTrendBreakoutStrategy.identifier))
        XCTAssertTrue(ids.contains(SuperTrendATRContinuationStrategy.identifier))
        XCTAssertTrue(ids.contains(RSITrendContinuationStrategy.identifier))
    }

    func testSignalDraftRequiresStopLossAndTakeProfit() throws {
        let missingStop = StrategySignalDraft(
            strategyID: "fixture",
            symbol: FuturesSymbol("BTCUSDT"),
            side: .buy,
            entryPrice: 100,
            stopLoss: nil,
            takeProfit: 120,
            reason: "fixture",
            generatedAt: Date()
        )

        XCTAssertThrowsError(try missingStop.validated()) { error in
            XCTAssertEqual(error as? TradingDomainError, .missingStopLoss)
        }

        let missingTake = StrategySignalDraft(
            strategyID: "fixture",
            symbol: FuturesSymbol("BTCUSDT"),
            side: .buy,
            entryPrice: 100,
            stopLoss: 90,
            takeProfit: nil,
            reason: "fixture",
            generatedAt: Date()
        )

        XCTAssertThrowsError(try missingTake.validated()) { error in
            XCTAssertEqual(error as? TradingDomainError, .missingTakeProfit)
        }
    }

    func testPaperRunnerRejectsSymbolOutsideWatchlist() throws {
        let logStore = InMemoryTradeEventLogStore()
        let runner = PaperTradingRunner(
            strategyRegistry: StrategyRegistry(),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        XCTAssertThrowsError(
            try runner.start(
                symbol: FuturesSymbol("SOLUSDT"),
                watchlist: [FuturesSymbol("BTCUSDT")],
                timeframe: .fifteenMinutes,
                candles: [],
                config: .default
            )
        ) { error in
            XCTAssertEqual(error as? TradingDomainError, .selectedSymbolNotInWatchlist(FuturesSymbol("SOLUSDT")))
        }
    }

    func testPaperRunnerDoesNotPersistNoopEvaluation() throws {
        let logStore = InMemoryTradeEventLogStore()
        let runner = PaperTradingRunner(
            strategyRegistry: StrategyRegistry(),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        _ = try runner.start(
            symbol: FuturesSymbol("BTCUSDT"),
            watchlist: [FuturesSymbol("BTCUSDT")],
            timeframe: .fifteenMinutes,
            candles: [],
            config: .default
        )

        let logs = try logStore.loadRecent(limit: 10)
        XCTAssertEqual(logs.count, 0)
    }

    func testPaperRunnerPersistsDetailedPaperOrderWhenSignalExists() throws {
        let logStore = InMemoryTradeEventLogStore()
        let runner = PaperTradingRunner(
            strategyRegistry: StrategyRegistry(strategies: [FixtureSignalStrategy()]),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        _ = try runner.start(
            symbol: FuturesSymbol("BTCUSDT"),
            watchlist: [FuturesSymbol("BTCUSDT")],
            timeframe: .fifteenMinutes,
            candles: [],
            config: StrategyConfig(strategyID: FixtureSignalStrategy.identifier, leverage: 2, parameters: [:])
        )

        let log = try XCTUnwrap(try logStore.loadRecent(limit: 10).first)
        XCTAssertEqual(log.category, .paperOrder)
        XCTAssertTrue(log.message.contains("Paper buy order"))
        XCTAssertTrue(log.message.contains("leverage 2x"))
        XCTAssertTrue(log.isPersistentTradingRecord)
    }

    func testPaperRunnerBlocksLeverageAboveAutomationLimit() throws {
        let logStore = InMemoryTradeEventLogStore()
        let runner = PaperTradingRunner(
            strategyRegistry: StrategyRegistry(strategies: [FixtureSignalStrategy()]),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        let evaluation = try runner.start(
            symbol: FuturesSymbol("BTCUSDT"),
            watchlist: [FuturesSymbol("BTCUSDT")],
            timeframe: .fifteenMinutes,
            candles: [],
            config: StrategyConfig(strategyID: FixtureSignalStrategy.identifier, leverage: 11, parameters: [:])
        )

        let log = try XCTUnwrap(try logStore.loadRecent(limit: 10).first)
        XCTAssertEqual(evaluation, .noSignal)
        XCTAssertEqual(log.category, .risk)
        XCTAssertTrue(log.message.contains("최대 10x"))
    }

    func testRiskPolicyBlocksLeveragedStopLossAtThirtyPercentOrMore() throws {
        let signal = try StrategySignalDraft(
            strategyID: "fixture",
            symbol: FuturesSymbol("BTCUSDT"),
            side: .buy,
            entryPrice: 100,
            stopLoss: 96,
            takeProfit: 108,
            reason: "fixture",
            generatedAt: Date(timeIntervalSince1970: 1)
        ).validated()

        let decision = StrategyRiskPolicy.decision(for: signal, leverage: 8)

        XCTAssertFalse(decision.isAllowed)
        XCTAssertTrue(decision.reason.contains("30"))
    }

    func testBacktestEngineReportsWinningTrades() throws {
        let registry = StrategyRegistry(strategies: [FixtureSignalStrategy()])
        let engine = BacktestEngine(strategyRegistry: registry)
        let candles = DemoDataSeeder.makeCandles(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            count: 80
        ).map { candle in
            Candle(
                productType: candle.productType,
                symbol: candle.symbol,
                timeframe: candle.timeframe,
                openTime: candle.openTime,
                open: 100,
                high: 121,
                low: 99,
                close: 100,
                volume: candle.volume,
                isClosed: true
            )
        }

        let result = try engine.run(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: candles,
            config: StrategyConfig(strategyID: FixtureSignalStrategy.identifier, leverage: 1, parameters: [:])
        )

        XCTAssertGreaterThan(result.totalTrades, 0)
        XCTAssertEqual(result.winRatePercent, 100)
        XCTAssertGreaterThanOrEqual(result.averageRewardRiskRatio, 2)
    }
}

struct FixedClock: Clock {
    let now: Date
}

private struct FixtureSignalStrategy: TradingStrategy {
    static let identifier = "fixture-signal"

    let definition = StrategyDefinition(
        id: FixtureSignalStrategy.identifier,
        name: "Fixture Signal",
        summary: "Always emits one fixture signal",
        defaultConfig: StrategyConfig(strategyID: FixtureSignalStrategy.identifier, leverage: 1, parameters: [:])
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        .signal(try StrategySignalDraft(
            strategyID: FixtureSignalStrategy.identifier,
            symbol: context.symbol,
            side: .buy,
            entryPrice: 100,
            stopLoss: 90,
            takeProfit: 120,
            reason: "fixture",
            generatedAt: context.generatedAt
        ).validated())
    }
}
