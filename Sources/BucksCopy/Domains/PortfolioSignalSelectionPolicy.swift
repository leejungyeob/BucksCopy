import Foundation

struct TradeCandidate: Equatable, Identifiable {
    let id: String
    let signal: StrategySignal
    let timeframe: CandleTimeframe
    let candleOpenTime: Date
    let leverage: Int
    let riskDecision: RiskDecision

    init(
        signal: StrategySignal,
        timeframe: CandleTimeframe,
        candleOpenTime: Date,
        leverage: Int,
        riskDecision: RiskDecision
    ) {
        self.id = [
            signal.symbol.rawValue,
            timeframe.rawValue,
            signal.strategyID,
            "\(Int(candleOpenTime.timeIntervalSince1970))",
            signal.id.uuidString
        ].joined(separator: ":")
        self.signal = signal
        self.timeframe = timeframe
        self.candleOpenTime = candleOpenTime
        self.leverage = leverage
        self.riskDecision = riskDecision
    }
}

struct PortfolioSignalScore: Equatable {
    let rewardRiskRatio: Decimal
    let expectedProfitPercent: Decimal
    let expectedProfitAmount: Decimal?
    let accountRiskPercent: Decimal

    func isStrictlyBetter(than other: PortfolioSignalScore) -> Bool {
        if rewardRiskRatio != other.rewardRiskRatio {
            return rewardRiskRatio > other.rewardRiskRatio
        }

        if let expectedProfitAmount,
           let otherExpectedProfitAmount = other.expectedProfitAmount,
           expectedProfitAmount != otherExpectedProfitAmount {
            return expectedProfitAmount > otherExpectedProfitAmount
        }

        if expectedProfitPercent != other.expectedProfitPercent {
            return expectedProfitPercent > other.expectedProfitPercent
        }

        if accountRiskPercent != other.accountRiskPercent {
            return accountRiskPercent < other.accountRiskPercent
        }

        return false
    }
}

struct PortfolioOpenPositionAssessment: Equatable {
    let position: PositionSnapshot
    let score: PortfolioSignalScore
    let isScored: Bool
}

enum PortfolioSignalDecision: Equatable {
    case noAction
    case enter(TradeCandidate, reason: String)
    case replace(existing: PortfolioOpenPositionAssessment, with: TradeCandidate, reason: String)
    case holdExisting(PortfolioOpenPositionAssessment, bestCandidate: TradeCandidate, reason: String)
}

enum PortfolioSignalSelectionPolicy {
    static func decision(
        candidates: [TradeCandidate],
        openPositions: [PositionSnapshot],
        accountEquity: Decimal? = nil
    ) -> PortfolioSignalDecision {
        let occupiedPositions = openPositions
            .filter { $0.total > 0 && $0.side != .unknown }
        let blockedCandidates = candidates.filter {
            occupiedPosition(
                for: $0,
                in: occupiedPositions,
                accountEquity: accountEquity
            ) != nil
        }
        let availableCandidates = candidates.filter { candidate in
            blockedCandidates.contains { $0.id == candidate.id } == false
        }

        guard let bestCandidate = bestCandidate(in: availableCandidates, accountEquity: accountEquity) else {
            guard let blockedCandidate = bestCandidate(in: blockedCandidates, accountEquity: accountEquity),
                  let existing = occupiedPosition(
                    for: blockedCandidate,
                    in: occupiedPositions,
                    accountEquity: accountEquity
                  ) else {
                return .noAction
            }
            return .holdExisting(
                existing,
                bestCandidate: blockedCandidate,
                reason: "이미 점유된 포지션 슬롯이라 새 신호를 받지 않습니다. 기존 \(positionSummary(existing))가 정리될 때까지 \(summary(for: blockedCandidate, accountEquity: accountEquity)) 신규 진입은 보류합니다."
            )
        }

        if blockedCandidates.isEmpty == false {
            return .enter(
                bestCandidate,
                reason: "이미 점유된 포지션 슬롯의 신호는 보류하고, 비어 있는 방향 슬롯의 최우선 신호를 선택했습니다. \(summary(for: bestCandidate, accountEquity: accountEquity))"
            )
        }

        guard occupiedPositions.isEmpty == false else {
            return .enter(
                bestCandidate,
                reason: "열려 있는 포지션이 없어 최우선 신호를 신규 진입 대상으로 선택했습니다. \(summary(for: bestCandidate, accountEquity: accountEquity))"
            )
        }

        return .enter(
            bestCandidate,
            reason: "현재 열린 포지션과 다른 심볼/방향 슬롯의 최우선 신호를 추가 진입 대상으로 선택했습니다. \(summary(for: bestCandidate, accountEquity: accountEquity))"
        )
    }

    private static func occupiedPosition(
        for candidate: TradeCandidate,
        in openPositions: [PositionSnapshot],
        accountEquity: Decimal?
    ) -> PortfolioOpenPositionAssessment? {
        let candidateSide = PositionSide(openedBy: candidate.signal.side)
        guard let position = openPositions.first(where: {
            $0.symbol == candidate.signal.symbol &&
                ($0.side == candidateSide || $0.positionMode == .oneWay)
        }) else {
            return nil
        }

        return assessment(for: position, accountEquity: accountEquity)
    }

    static func score(
        for candidate: TradeCandidate,
        accountEquity: Decimal? = nil
    ) -> PortfolioSignalScore {
        let rewardRiskRatio = candidate.signal.plannedRewardRiskRatio ?? 0
        let grossRewardPercent = (candidate.signal.leveragedSplitTakeProfitPercent(leverage: candidate.leverage) ?? 0) *
            candidate.riskDecision.positionMarginRatio
        let netRewardPercent = TradingFeePolicy.netLeveragedReturnPercent(
            grossLeveragedReturnPercent: grossRewardPercent,
            exitExecution: .takeProfitLimit,
            leverage: candidate.leverage,
            positionMarginRatio: candidate.riskDecision.positionMarginRatio
        )
        let expectedAmount = accountEquity.flatMap { equity in
            equity > 0 ? equity * netRewardPercent / 100 : nil
        }

        return PortfolioSignalScore(
            rewardRiskRatio: rewardRiskRatio,
            expectedProfitPercent: netRewardPercent,
            expectedProfitAmount: expectedAmount,
            accountRiskPercent: candidate.riskDecision.accountRiskPercent
        )
    }

    static func assessment(
        for position: PositionSnapshot,
        accountEquity: Decimal? = nil
    ) -> PortfolioOpenPositionAssessment {
        guard let takeProfit = position.takeProfit,
              let stopLoss = position.stopLoss,
              position.markPrice > 0,
              position.leverage > 0 else {
            return PortfolioOpenPositionAssessment(
                position: position,
                score: PortfolioSignalScore(
                    rewardRiskRatio: 0,
                    expectedProfitPercent: 0,
                    expectedProfitAmount: nil,
                    accountRiskPercent: 0
                ),
                isScored: false
            )
        }

        let reward: Decimal
        let risk: Decimal
        switch position.side {
        case .long:
            reward = takeProfit - position.markPrice
            risk = position.markPrice - stopLoss
        case .short:
            reward = position.markPrice - takeProfit
            risk = stopLoss - position.markPrice
        case .unknown:
            reward = 0
            risk = 0
        }

        guard reward > 0, risk > 0 else {
            return PortfolioOpenPositionAssessment(
                position: position,
                score: PortfolioSignalScore(
                    rewardRiskRatio: 0,
                    expectedProfitPercent: 0,
                    expectedProfitAmount: nil,
                    accountRiskPercent: 0
                ),
                isScored: false
            )
        }

        let expectedAmount = reward * position.total
        let expectedPercent: Decimal
        if let accountEquity, accountEquity > 0 {
            expectedPercent = expectedAmount / accountEquity * 100
        } else {
            expectedPercent = reward / position.markPrice * 100 * Decimal(position.leverage)
        }

        return PortfolioOpenPositionAssessment(
            position: position,
            score: PortfolioSignalScore(
                rewardRiskRatio: reward / risk,
                expectedProfitPercent: expectedPercent,
                expectedProfitAmount: expectedAmount,
                accountRiskPercent: 0
            ),
            isScored: true
        )
    }

    private static func bestCandidate(
        in candidates: [TradeCandidate],
        accountEquity: Decimal?
    ) -> TradeCandidate? {
        candidates.sorted {
            let lhsScore = score(for: $0, accountEquity: accountEquity)
            let rhsScore = score(for: $1, accountEquity: accountEquity)

            if lhsScore.isStrictlyBetter(than: rhsScore) {
                return true
            }
            if rhsScore.isStrictlyBetter(than: lhsScore) {
                return false
            }
            if $0.candleOpenTime != $1.candleOpenTime {
                return $0.candleOpenTime > $1.candleOpenTime
            }
            if $0.timeframe.duration != $1.timeframe.duration {
                return $0.timeframe.duration < $1.timeframe.duration
            }
            if $0.signal.strategyID != $1.signal.strategyID {
                return $0.signal.strategyID < $1.signal.strategyID
            }
            return $0.signal.symbol.rawValue < $1.signal.symbol.rawValue
        }.first
    }

    private static func bestPosition(
        in assessments: [PortfolioOpenPositionAssessment]
    ) -> PortfolioOpenPositionAssessment? {
        assessments.sorted {
            if $0.score.isStrictlyBetter(than: $1.score) {
                return true
            }
            if $1.score.isStrictlyBetter(than: $0.score) {
                return false
            }
            if $0.isScored != $1.isScored {
                return $0.isScored
            }
            return $0.position.symbol.rawValue < $1.position.symbol.rawValue
        }.first
    }

    private static func summary(
        for candidate: TradeCandidate,
        accountEquity: Decimal?
    ) -> String {
        let candidateScore = score(for: candidate, accountEquity: accountEquity)
        return "\(candidate.signal.symbol.rawValue) \(candidate.timeframe.rawValue) \(candidate.signal.strategyID) \(candidate.signal.side.rawValue), 손익비 \(candidateScore.rewardRiskRatio.riskText):1, 기대순익 \(candidateScore.expectedProfitPercent.riskText)%\(amountText(candidateScore.expectedProfitAmount))"
    }

    private static func positionSummary(_ assessment: PortfolioOpenPositionAssessment) -> String {
        "\(assessment.position.symbol.rawValue) \(assessment.position.side.rawValue), 남은 손익비 \(assessment.score.rewardRiskRatio.riskText):1, 기대수익 \(assessment.score.expectedProfitPercent.riskText)%\(amountText(assessment.score.expectedProfitAmount))"
    }

    private static func amountText(_ amount: Decimal?) -> String {
        guard let amount else { return "" }
        return ", 예상금액 \(amount.riskText) USDT"
    }
}
