import XCTest
@testable import BucksCopy

final class PortfolioSignalSelectionPolicyTests: XCTestCase {
    func testPrioritizesRewardRiskBeforeExpectedProfitAmount() throws {
        let higherRewardRisk = try candidate(
            strategyID: "high-rr",
            stopLoss: 98,
            takeProfit: 106,
            positionMarginRatio: Decimal(string: "0.10")!
        )
        let higherExpectedProfit = try candidate(
            strategyID: "high-profit",
            stopLoss: 99,
            takeProfit: 102,
            positionMarginRatio: Decimal(string: "0.80")!
        )

        let decision = PortfolioSignalSelectionPolicy.decision(
            candidates: [higherExpectedProfit, higherRewardRisk],
            openPositions: [],
            accountEquity: 100
        )

        guard case .enter(let selected, _) = decision else {
            return XCTFail("Expected a new entry decision")
        }
        XCTAssertEqual(selected.signal.strategyID, "high-rr")
    }

    func testUsesExpectedProfitAmountAsTieBreaker() throws {
        let lowerExpectedProfit = try candidate(
            strategyID: "small-size",
            stopLoss: 98,
            takeProfit: 104,
            positionMarginRatio: Decimal(string: "0.10")!
        )
        let higherExpectedProfit = try candidate(
            strategyID: "large-size",
            stopLoss: 98,
            takeProfit: 104,
            positionMarginRatio: Decimal(string: "0.50")!
        )

        let decision = PortfolioSignalSelectionPolicy.decision(
            candidates: [lowerExpectedProfit, higherExpectedProfit],
            openPositions: [],
            accountEquity: 100
        )

        guard case .enter(let selected, _) = decision else {
            return XCTFail("Expected a new entry decision")
        }
        XCTAssertEqual(selected.signal.strategyID, "large-size")
    }

    func testReplacesOpenPositionWhenNewSignalScoresHigher() throws {
        let existing = position(
            symbol: FuturesSymbol("BTCUSDT"),
            side: .long,
            markPrice: 100,
            takeProfit: 104,
            stopLoss: 98
        )
        let strongerSignal = try candidate(
            strategyID: "stronger",
            stopLoss: 98,
            takeProfit: 106,
            positionMarginRatio: Decimal(string: "0.30")!
        )

        let decision = PortfolioSignalSelectionPolicy.decision(
            candidates: [strongerSignal],
            openPositions: [existing],
            accountEquity: 100
        )

        guard case .replace(let assessedPosition, let selected, _) = decision else {
            return XCTFail("Expected replacement decision")
        }
        XCTAssertEqual(assessedPosition.position.symbol, FuturesSymbol("BTCUSDT"))
        XCTAssertEqual(selected.signal.strategyID, "stronger")
    }

    func testHoldsExistingPositionWhenItScoresAtLeastAsWellAsNewSignal() throws {
        let existing = position(
            symbol: FuturesSymbol("BTCUSDT"),
            side: .long,
            markPrice: 100,
            takeProfit: 106,
            stopLoss: 98
        )
        let weakerSignal = try candidate(
            strategyID: "weaker",
            stopLoss: 99,
            takeProfit: 102,
            positionMarginRatio: Decimal(string: "0.80")!
        )

        let decision = PortfolioSignalSelectionPolicy.decision(
            candidates: [weakerSignal],
            openPositions: [existing],
            accountEquity: 100
        )

        guard case .holdExisting(let assessedPosition, let bestCandidate, _) = decision else {
            return XCTFail("Expected hold decision")
        }
        XCTAssertEqual(assessedPosition.position.symbol, FuturesSymbol("BTCUSDT"))
        XCTAssertEqual(bestCandidate.signal.strategyID, "weaker")
    }
}

private func candidate(
    strategyID: String,
    stopLoss: Decimal,
    takeProfit: Decimal,
    positionMarginRatio: Decimal
) throws -> PaperTradeCandidate {
    let signal = try StrategySignalDraft(
        strategyID: strategyID,
        symbol: FuturesSymbol("BTCUSDT"),
        side: .buy,
        entryPrice: 100,
        stopLoss: stopLoss,
        takeProfit: takeProfit,
        reason: strategyID,
        generatedAt: Date(timeIntervalSince1970: 1)
    ).validated()
    let riskDecision = RiskDecision(
        id: UUID(),
        intentID: signal.id,
        isAllowed: true,
        reason: "fixture",
        positionMarginRatio: positionMarginRatio,
        accountRiskPercent: 5,
        decidedAt: Date(timeIntervalSince1970: 1)
    )

    return PaperTradeCandidate(
        signal: signal,
        timeframe: .fifteenMinutes,
        candleOpenTime: Date(timeIntervalSince1970: 1),
        leverage: 10,
        riskDecision: riskDecision
    )
}

private func position(
    symbol: FuturesSymbol,
    side: PositionSide,
    markPrice: Decimal,
    takeProfit: Decimal,
    stopLoss: Decimal
) -> PositionSnapshot {
    PositionSnapshot(
        symbol: symbol,
        side: side,
        total: 1,
        available: 1,
        openPriceAverage: markPrice,
        markPrice: markPrice,
        unrealizedProfitLoss: 0,
        leverage: 10,
        marginMode: "crossed",
        liquidationPrice: nil,
        takeProfit: takeProfit,
        stopLoss: stopLoss,
        createdAt: nil,
        updatedAt: nil
    )
}
