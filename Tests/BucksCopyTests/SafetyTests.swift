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
}
