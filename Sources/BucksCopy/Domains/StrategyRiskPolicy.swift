import Foundation

enum StrategyRiskPolicy {
    static let maximumAutoTradingLeverage = 10
    static let minimumRewardRiskRatio: Decimal = 2
    static let maximumLeveragedStopLossPercent: Decimal = 30

    static func decision(
        for signal: StrategySignal,
        leverage: Int,
        decidedAt: Date = Date()
    ) -> RiskDecision {
        let blockedReason: String?

        if leverage <= 0 {
            blockedReason = "자동매매 레버리지는 1x 이상이어야 합니다."
        } else if leverage > maximumAutoTradingLeverage {
            blockedReason = "자동매매 레버리지는 최대 \(maximumAutoTradingLeverage)x까지만 허용됩니다."
        } else if signal.hasValidPriceLayout == false {
            blockedReason = "진입가, 손절가, 익절가 방향이 맞지 않아 신호를 제외했습니다."
        } else if let ratio = signal.plannedRewardRiskRatio,
                  ratio < minimumRewardRiskRatio {
            blockedReason = "손익비가 \(minimumRewardRiskRatio.riskText):1 미만이라 신호를 제외했습니다. 현재 \(ratio.riskText):1"
        } else if signal.plannedRewardRiskRatio == nil {
            blockedReason = "손익비를 계산할 수 없어 신호를 제외했습니다."
        } else if let leveragedLoss = signal.leveragedStopLossPercent(leverage: leverage),
                  leveragedLoss >= maximumLeveragedStopLossPercent {
            blockedReason = "손절폭과 레버리지를 합친 예상 손실이 \(maximumLeveragedStopLossPercent.riskText)% 이상이라 제외했습니다. 현재 \(leveragedLoss.riskText)%"
        } else if signal.leveragedStopLossPercent(leverage: leverage) == nil {
            blockedReason = "손절 위험을 계산할 수 없어 신호를 제외했습니다."
        } else if let leveragedReward = signal.leveragedTakeProfitPercent(leverage: leverage) {
            let roundTripFee = TradingFeePolicy.roundTripTakerFeePercent(leverage: leverage)
            blockedReason = leveragedReward <= roundTripFee
                ? "익절 기대 수익이 왕복 수수료보다 작거나 같아 제외했습니다. 익절 \(leveragedReward.riskText)%, 수수료 \(roundTripFee.riskText)%"
                : nil
        } else if signal.leveragedTakeProfitPercent(leverage: leverage) == nil {
            blockedReason = "익절 기대 수익을 계산할 수 없어 신호를 제외했습니다."
        } else {
            blockedReason = nil
        }

        return RiskDecision(
            id: UUID(),
            intentID: signal.id,
            isAllowed: blockedReason == nil,
            reason: blockedReason ?? "리스크 기준 통과",
            decidedAt: decidedAt
        )
    }
}

extension StrategySignal {
    var hasValidPriceLayout: Bool {
        switch side {
        case .buy:
            return stopLoss < entryPrice && entryPrice < takeProfit
        case .sell:
            return takeProfit < entryPrice && entryPrice < stopLoss
        }
    }

    var plannedRewardRiskRatio: Decimal? {
        guard hasValidPriceLayout else { return nil }
        let risk = absoluteDecimal(entryPrice - stopLoss)
        let reward = absoluteDecimal(takeProfit - entryPrice)
        guard risk > 0 else { return nil }
        return reward / risk
    }

    var stopLossPercent: Decimal? {
        guard entryPrice > 0, hasValidPriceLayout else { return nil }
        let risk = absoluteDecimal(entryPrice - stopLoss)
        return risk / entryPrice * 100
    }

    func leveragedStopLossPercent(leverage: Int) -> Decimal? {
        guard let stopLossPercent else { return nil }
        return stopLossPercent * Decimal(leverage)
    }

    func leveragedTakeProfitPercent(leverage: Int) -> Decimal? {
        guard entryPrice > 0, hasValidPriceLayout else { return nil }
        let reward = absoluteDecimal(takeProfit - entryPrice)
        return reward / entryPrice * 100 * Decimal(leverage)
    }
}

extension Decimal {
    var riskText: String {
        let number = NSDecimalNumber(decimal: self)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal
        return formatter.string(from: number) ?? number.stringValue
    }
}

func absoluteDecimal(_ value: Decimal) -> Decimal {
    value < 0 ? -value : value
}
