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

    func testBlocksSameSymbolSameSideSignalUntilPositionCloses() throws {
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

        guard case .holdExisting(let assessedPosition, let bestCandidate, _) = decision else {
            return XCTFail("Expected same-side hold decision")
        }
        XCTAssertEqual(assessedPosition.position.symbol, FuturesSymbol("BTCUSDT"))
        XCTAssertEqual(bestCandidate.signal.strategyID, "stronger")
    }

    func testAllowsOppositeSideHedgeSignalWhilePositionIsOpen() throws {
        let existing = position(
            symbol: FuturesSymbol("BTCUSDT"),
            side: .long,
            markPrice: 100,
            takeProfit: 106,
            stopLoss: 98
        )
        let shortSignal = try candidate(
            strategyID: "short-hedge",
            side: .sell,
            stopLoss: 102,
            takeProfit: 94,
            positionMarginRatio: Decimal(string: "0.20")!
        )

        let decision = PortfolioSignalSelectionPolicy.decision(
            candidates: [shortSignal],
            openPositions: [existing],
            accountEquity: 100
        )

        guard case .enter(let selected, _) = decision else {
            return XCTFail("Expected opposite-side entry decision")
        }
        XCTAssertEqual(selected.signal.strategyID, "short-hedge")
        XCTAssertEqual(selected.signal.side, .sell)
    }

    func testBlocksOppositeSideSignalWhenPositionIsOneWayMode() throws {
        let existing = position(
            symbol: FuturesSymbol("BTCUSDT"),
            side: .long,
            markPrice: 100,
            takeProfit: 106,
            stopLoss: 98,
            positionMode: .oneWay
        )
        let shortSignal = try candidate(
            strategyID: "short-one-way-blocked",
            side: .sell,
            stopLoss: 102,
            takeProfit: 94,
            positionMarginRatio: Decimal(string: "0.20")!
        )

        let decision = PortfolioSignalSelectionPolicy.decision(
            candidates: [shortSignal],
            openPositions: [existing],
            accountEquity: 100
        )

        guard case .holdExisting(let assessedPosition, let bestCandidate, _) = decision else {
            return XCTFail("Expected one-way opposite-side hold decision")
        }
        XCTAssertEqual(assessedPosition.position.positionMode, .oneWay)
        XCTAssertEqual(bestCandidate.signal.strategyID, "short-one-way-blocked")
    }
}

private func candidate(
    strategyID: String,
    side: TradeSide = .buy,
    stopLoss: Decimal,
    takeProfit: Decimal,
    positionMarginRatio: Decimal
) throws -> TradeCandidate {
    let signal = try StrategySignalDraft(
        strategyID: strategyID,
        symbol: FuturesSymbol("BTCUSDT"),
        side: side,
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

    return TradeCandidate(
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
    stopLoss: Decimal,
    positionMode: PositionMode = .hedge
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
        positionMode: positionMode,
        liquidationPrice: nil,
        takeProfit: takeProfit,
        stopLoss: stopLoss,
        createdAt: nil,
        updatedAt: nil
    )
}
