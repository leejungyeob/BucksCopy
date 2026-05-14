import XCTest
@testable import BucksCopy

final class SafetyTests: XCTestCase {
    func testDisabledLiveOrderClientAlwaysThrows() async throws {
        let client = DisabledLiveOrderClient()
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
        let intent = OrderIntent(id: UUID(), signal: signal, createdAt: Date())

        do {
            try await client.placeLiveOrder(intent)
            XCTFail("Live order placement must remain disabled.")
        } catch {
            XCTAssertEqual(error as? TradingDomainError, .liveTradingDisabled)
            XCTAssertEqual(client.attemptedOrderCount, 1)
        }
    }

    func testProtectionPlanBuildsTakeProfitLimitAndStopLossMarketOrders() throws {
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

        XCTAssertEqual(orders.count, 2)
        XCTAssertEqual(orders[0].kind, .takeProfit)
        XCTAssertEqual(orders[0].execution, .limit)
        XCTAssertEqual(orders[0].executePrice, 120)
        XCTAssertEqual(orders[1].kind, .stopLoss)
        XCTAssertEqual(orders[1].execution, .market)
        XCTAssertNil(orders[1].executePrice)
        XCTAssertEqual(orders[0].holdSide, .long)
        XCTAssertEqual(orders[1].holdSide, .long)
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

        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts[0].attempts, 6)
        XCTAssertEqual(receipts[1].attempts, 1)
        XCTAssertEqual(placer.attemptsByKind[.takeProfit], 6)
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
                .protectionOrderRetryExhausted(kind: .takeProfit, attempts: 6)
            )
            XCTAssertEqual(placer.attemptsByKind[.takeProfit], 6)
        }
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
