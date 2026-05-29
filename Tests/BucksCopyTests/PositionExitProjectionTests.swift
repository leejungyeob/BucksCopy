import XCTest
@testable import BucksCopy

final class PositionExitProjectionTests: XCTestCase {
    func testLongPositionExitProjectionUsesSplitTakeProfitAndFullStopLoss() {
        let position = makePosition(side: .long, total: 1, entry: 100, leverage: 10)

        let partial = PositionExitProjection.partialTakeProfit(position: position, price: 110)
        let final = PositionExitProjection.finalTakeProfit(position: position, partialPrice: 110, finalPrice: 120)
        let stop = PositionExitProjection.stopLoss(position: position, price: 90)

        XCTAssertEqual(partial?.amount, 5)
        XCTAssertEqual(partial?.marginReturnPercent, 50)
        XCTAssertEqual(final?.amount, 15)
        XCTAssertEqual(final?.marginReturnPercent, 150)
        XCTAssertEqual(stop?.amount, -10)
        XCTAssertEqual(stop?.marginReturnPercent, -100)
    }

    func testShortPositionExitProjectionUsesSplitTakeProfitAndFullStopLoss() {
        let position = makePosition(side: .short, total: 2, entry: 100, leverage: 10)

        let partial = PositionExitProjection.partialTakeProfit(position: position, price: 90)
        let final = PositionExitProjection.finalTakeProfit(position: position, partialPrice: 90, finalPrice: 80)
        let stop = PositionExitProjection.stopLoss(position: position, price: 110)

        XCTAssertEqual(partial?.amount, 10)
        XCTAssertEqual(partial?.marginReturnPercent, 50)
        XCTAssertEqual(final?.amount, 30)
        XCTAssertEqual(final?.marginReturnPercent, 150)
        XCTAssertEqual(stop?.amount, -20)
        XCTAssertEqual(stop?.marginReturnPercent, -100)
    }
}

private func makePosition(
    side: PositionSide,
    total: Decimal,
    entry: Decimal,
    leverage: Int
) -> PositionSnapshot {
    PositionSnapshot(
        symbol: FuturesSymbol("BTCUSDT"),
        side: side,
        total: total,
        available: total,
        openPriceAverage: entry,
        markPrice: entry,
        unrealizedProfitLoss: 0,
        leverage: leverage,
        marginMode: "isolated",
        positionMode: .hedge,
        liquidationPrice: nil,
        takeProfit: nil,
        stopLoss: nil,
        createdAt: nil,
        updatedAt: nil
    )
}
