import XCTest
@testable import BucksCopy

final class SafetyTests: XCTestCase {
    func testLiveTradeExecutorPlacesEntryAndProtectionAfterSizing() async throws {
        let client = TestLiveOrderClient()
        let logStore = InMemoryTradeEventLogStore()
        let executor = LiveTradeExecutor(
            orderPlacer: client,
            leverageSetter: client,
            protectionInstaller: ExchangeProtectionInstaller(
                orderPlacer: client,
                retryPolicy: ExchangeProtectionRetryPolicy(retryDelayNanoseconds: 0)
            ),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )
        let evaluator = TradingSignalEvaluator(
            strategyRegistry: StrategyRegistry(strategies: []),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )
        let candidate = liveTradeCandidate()

        let result = try await executor.execute(
            decision: .enter(candidate, reason: "fixture decision"),
            accountEquity: 1_000,
            contractSpecs: [liveContractSpec(symbol: candidate.signal.symbol)],
            signalEvaluator: evaluator
        )

        XCTAssertTrue(result.didSubmitOrder)
        XCTAssertEqual(client.leverageRequests.count, 1)
        XCTAssertEqual(client.marketOrders.count, 1)
        XCTAssertEqual(client.marketOrders.first?.size, 5)
        XCTAssertEqual(client.protectionOrders.count, 3)
        XCTAssertEqual(result.protectionReceipts.map(\.kind), [.takeProfit, .takeProfit, .stopLoss])
        XCTAssertTrue(try logStore.loadRecent(limit: 10).contains { $0.category == .liveOrder })
    }

    func testLiveTradeExecutorFailClosesWhenProtectionInstallFails() async throws {
        let client = TestLiveOrderClient()
        let failingProtectionPlacer = FlakyProtectionOrderPlacer(failuresBeforeSuccess: 99)
        let logStore = InMemoryTradeEventLogStore()
        let executor = LiveTradeExecutor(
            orderPlacer: client,
            leverageSetter: client,
            protectionInstaller: ExchangeProtectionInstaller(
                orderPlacer: failingProtectionPlacer,
                retryPolicy: ExchangeProtectionRetryPolicy(retryDelayNanoseconds: 0)
            ),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )
        let evaluator = TradingSignalEvaluator(
            strategyRegistry: StrategyRegistry(strategies: []),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )
        let candidate = liveTradeCandidate()

        do {
            _ = try await executor.execute(
                decision: .enter(candidate, reason: "fixture decision"),
                accountEquity: 1_000,
                contractSpecs: [liveContractSpec(symbol: candidate.signal.symbol)],
                signalEvaluator: evaluator
            )
            XCTFail("Protection failure should stop live execution.")
        } catch {
            XCTAssertEqual(
                error as? TradingDomainError,
                .protectionOrderRetryExhausted(
                    kind: .takeProfit,
                    attempts: 6,
                    cause: "Bitget API 40000: fixture failure"
                )
            )
            XCTAssertEqual(client.marketOrders.count, 1)
            XCTAssertEqual(client.closeRequests.count, 1)
            XCTAssertTrue(try logStore.loadRecent(limit: 10).contains {
                $0.category == .risk &&
                    $0.message.contains("fail-closed")
            })
            XCTAssertTrue(try logStore.loadRecent(limit: 10).contains {
                $0.message.contains("Bitget API 40000: fixture failure")
            })
        }
    }

    func testLiveTradeExecutorDoesNotProtectOrCloseWhenFilledOrderHasNoPosition() async throws {
        let client = TestLiveOrderClient()
        let failingProtectionPlacer = FlakyProtectionOrderPlacer(failuresBeforeSuccess: 99)
        let positionRepository = SequencedPositionRepository(positionSnapshots: [[]])
        let logStore = InMemoryTradeEventLogStore()
        let executor = LiveTradeExecutor(
            orderPlacer: client,
            leverageSetter: client,
            protectionInstaller: ExchangeProtectionInstaller(
                orderPlacer: failingProtectionPlacer,
                retryPolicy: ExchangeProtectionRetryPolicy(retryDelayNanoseconds: 0)
            ),
            positionRepository: positionRepository,
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1)),
            positionVerificationDelayNanoseconds: 0
        )
        let evaluator = TradingSignalEvaluator(
            strategyRegistry: StrategyRegistry(strategies: []),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )
        let candidate = liveTradeCandidate()

        do {
            _ = try await executor.execute(
                decision: .enter(candidate, reason: "fixture decision"),
                accountEquity: 1_000,
                contractSpecs: [liveContractSpec(symbol: candidate.signal.symbol)],
                signalEvaluator: evaluator
            )
            XCTFail("Position confirmation should stop live protection.")
        } catch {
            XCTAssertEqual(
                error as? TradingDomainError,
                .liveEntryPositionNotConfirmed(client.marketOrders.first?.clientOid ?? "")
            )
            XCTAssertEqual(client.marketOrders.count, 1)
            XCTAssertEqual(client.closeRequests.count, 0)
            XCTAssertEqual(failingProtectionPlacer.attemptsByKind[.takeProfit], nil)
            XCTAssertTrue(try logStore.loadRecent(limit: 10).contains {
                $0.message.contains("Protection orders and fail-closed close were skipped")
            })
        }
    }

    func testLiveTradeExecutorSkipsFailClosedCloseWhenPositionDisappears() async throws {
        let client = TestLiveOrderClient()
        let failingProtectionPlacer = FlakyProtectionOrderPlacer(failuresBeforeSuccess: 99)
        let candidate = liveTradeCandidate()
        let positionRepository = SequencedPositionRepository(positionSnapshots: [
            [livePosition(symbol: candidate.signal.symbol, side: .long)],
            []
        ])
        let logStore = InMemoryTradeEventLogStore()
        let executor = LiveTradeExecutor(
            orderPlacer: client,
            leverageSetter: client,
            protectionInstaller: ExchangeProtectionInstaller(
                orderPlacer: failingProtectionPlacer,
                retryPolicy: ExchangeProtectionRetryPolicy(retryDelayNanoseconds: 0)
            ),
            positionRepository: positionRepository,
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1)),
            positionVerificationDelayNanoseconds: 0
        )
        let evaluator = TradingSignalEvaluator(
            strategyRegistry: StrategyRegistry(strategies: []),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        do {
            _ = try await executor.execute(
                decision: .enter(candidate, reason: "fixture decision"),
                accountEquity: 1_000,
                contractSpecs: [liveContractSpec(symbol: candidate.signal.symbol)],
                signalEvaluator: evaluator
            )
            XCTFail("Protection failure should stop live execution.")
        } catch {
            XCTAssertEqual(
                error as? TradingDomainError,
                .protectionOrderRetryExhausted(
                    kind: .takeProfit,
                    attempts: 6,
                    cause: "Bitget API 40000: fixture failure"
                )
            )
            XCTAssertEqual(client.marketOrders.count, 1)
            XCTAssertEqual(client.closeRequests.count, 0)
            XCTAssertTrue(try logStore.loadRecent(limit: 10).contains {
                $0.message.contains("Fail-closed close skipped")
            })
        }
    }

    func testProtectionPlanBuildsSplitTakeProfitLimitAndStopLossMarketOrders() throws {
        let signal = StrategySignal(
            id: UUID(),
            strategyID: "fixture",
            symbol: FuturesSymbol("BTCUSDT"),
            side: .buy,
            entryPrice: 100,
            stopLoss: 90,
            takeProfit: 120,
            reason: "fixture",
            generatedAt: Date()
        )
        let plan = ExchangeProtectionPlan(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            signal: signal,
            size: Decimal(string: "0.01")!,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let orders = plan.orders

        XCTAssertEqual(orders.count, 3)
        XCTAssertEqual(orders[0].kind, .takeProfit)
        XCTAssertEqual(orders[0].execution, .limit)
        XCTAssertEqual(orders[0].executePrice, 110)
        XCTAssertEqual(orders[0].size, Decimal(string: "0.005")!)
        XCTAssertEqual(orders[1].kind, .takeProfit)
        XCTAssertEqual(orders[1].execution, .limit)
        XCTAssertEqual(orders[1].executePrice, 120)
        XCTAssertEqual(orders[1].size, Decimal(string: "0.005")!)
        XCTAssertEqual(orders[2].kind, .stopLoss)
        XCTAssertEqual(orders[2].execution, .market)
        XCTAssertNil(orders[2].executePrice)
        XCTAssertEqual(orders[0].holdSide, .long)
        XCTAssertEqual(orders[1].holdSide, .long)
        XCTAssertEqual(orders[2].holdSide, .long)
    }

    func testProtectionInstallerRetriesFiveTimesAfterFailureBeforeSucceeding() async throws {
        let placer = FlakyProtectionOrderPlacer(failuresBeforeSuccess: 5)
        let installer = ExchangeProtectionInstaller(
            orderPlacer: placer,
            retryPolicy: ExchangeProtectionRetryPolicy(retryDelayNanoseconds: 0)
        )
        let signal = StrategySignal(
            id: UUID(),
            strategyID: "fixture",
            symbol: FuturesSymbol("BTCUSDT"),
            side: .buy,
            entryPrice: 100,
            stopLoss: 90,
            takeProfit: 120,
            reason: "fixture",
            generatedAt: Date()
        )
        let plan = ExchangeProtectionPlan(signal: signal, size: 1)

        let receipts = try await installer.installProtection(plan)

        XCTAssertEqual(receipts.count, 3)
        XCTAssertEqual(receipts[0].attempts, 6)
        XCTAssertEqual(receipts[1].attempts, 1)
        XCTAssertEqual(receipts[2].attempts, 1)
        XCTAssertEqual(placer.attemptsByKind[.takeProfit], 7)
        XCTAssertEqual(placer.attemptsByKind[.stopLoss], 1)
    }

    func testProtectionInstallerFailsAfterMinimumFiveRetries() async throws {
        let placer = FlakyProtectionOrderPlacer(failuresBeforeSuccess: 99)
        let installer = ExchangeProtectionInstaller(
            orderPlacer: placer,
            retryPolicy: ExchangeProtectionRetryPolicy(retryDelayNanoseconds: 0)
        )
        let signal = StrategySignal(
            id: UUID(),
            strategyID: "fixture",
            symbol: FuturesSymbol("BTCUSDT"),
            side: .sell,
            entryPrice: 100,
            stopLoss: 110,
            takeProfit: 80,
            reason: "fixture",
            generatedAt: Date()
        )
        let plan = ExchangeProtectionPlan(signal: signal, size: 1)

        do {
            _ = try await installer.installProtection(plan)
            XCTFail("Protection installer should fail after exhausting retries.")
        } catch {
            XCTAssertEqual(
                error as? TradingDomainError,
                .protectionOrderRetryExhausted(
                    kind: .takeProfit,
                    attempts: 6,
                    cause: "Bitget API 40000: fixture failure"
                )
            )
            XCTAssertEqual(placer.attemptsByKind[.takeProfit], 6)
        }
    }
}

private func liveTradeCandidate() -> TradeCandidate {
    let signal = StrategySignal(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
        strategyID: "fixture",
        symbol: FuturesSymbol("BTCUSDT"),
        side: .buy,
        entryPrice: 100,
        stopLoss: 90,
        takeProfit: 120,
        reason: "fixture",
        generatedAt: Date(timeIntervalSince1970: 1)
    )
    let riskDecision = RiskDecision(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
        intentID: signal.id,
        isAllowed: true,
        reason: "fixture",
        positionMarginRatio: Decimal(string: "0.25")!,
        accountRiskPercent: 5,
        decidedAt: Date(timeIntervalSince1970: 1)
    )
    return TradeCandidate(
        signal: signal,
        timeframe: .fifteenMinutes,
        candleOpenTime: Date(timeIntervalSince1970: 1),
        leverage: 2,
        riskDecision: riskDecision
    )
}

private func liveContractSpec(symbol: FuturesSymbol) -> ContractSpec {
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

private func livePosition(
    symbol: FuturesSymbol,
    side: PositionSide,
    total: Decimal = 5,
    positionMode: PositionMode = .hedge
) -> PositionSnapshot {
    PositionSnapshot(
        symbol: symbol,
        side: side,
        total: total,
        available: total,
        openPriceAverage: 100,
        markPrice: 100,
        unrealizedProfitLoss: 0,
        leverage: 2,
        marginMode: "isolated",
        positionMode: positionMode,
        liquidationPrice: nil,
        takeProfit: nil,
        stopLoss: nil,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )
}

private final class SequencedPositionRepository: PositionRepository {
    private var positionSnapshots: [[PositionSnapshot]]
    private var index = 0

    init(positionSnapshots: [[PositionSnapshot]]) {
        self.positionSnapshots = positionSnapshots
    }

    func fetchPositions() async throws -> [PositionSnapshot] {
        guard positionSnapshots.isEmpty == false else { return [] }
        let snapshot = positionSnapshots[min(index, positionSnapshots.count - 1)]
        index += 1
        return snapshot
    }
}

private final class FlakyProtectionOrderPlacer: ExchangeProtectionOrderPlacing {
    private let failuresBeforeSuccess: Int
    private(set) var attemptsByKind: [ExchangeProtectionOrderKind: Int] = [:]

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func placeProtectionOrder(_ order: ExchangeProtectionOrder) async throws -> ExchangeProtectionReceipt {
        let nextAttempts = (attemptsByKind[order.kind] ?? 0) + 1
        attemptsByKind[order.kind] = nextAttempts
        if order.kind == .takeProfit, nextAttempts <= failuresBeforeSuccess {
            throw BitgetClientError.apiError(code: "40000", message: "fixture failure")
        }
        return ExchangeProtectionReceipt(
            orderID: "order-\(order.kind.rawValue)",
            clientOid: order.clientOid,
            kind: order.kind,
            attempts: 1
        )
    }
}
