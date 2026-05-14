import Foundation

enum StrategyRiskPolicy {
    static let maximumAutoTradingLeverage = 10
    static let minimumRewardRiskRatio: Decimal = 2
    static let defaultMaximumRiskPerTradePercent: Decimal = 12
    static let maximumConfigurableRiskPerTradePercent: Decimal = 15
    static let minimumConfigurableRiskPerTradePercent: Decimal = 1
    static let defaultMaximumPositionMarginPercent: Decimal = 100
    static let maximumConfigurablePositionMarginPercent: Decimal = 100
    static let minimumConfigurablePositionMarginPercent: Decimal = 1

    static func decision(
        for signal: StrategySignal,
        leverage: Int,
        maximumRiskPerTradePercent: Decimal = defaultMaximumRiskPerTradePercent,
        maximumPositionMarginPercent: Decimal = defaultMaximumPositionMarginPercent,
        decidedAt: Date = Date()
    ) -> RiskDecision {
        let blockedReason: String?
        let positionMarginRatio: Decimal
        let accountRiskPercent: Decimal
        let riskLimit = clampedMaximumRiskPerTradePercent(maximumRiskPerTradePercent)
        let positionMarginLimit = clampedMaximumPositionMarginPercent(maximumPositionMarginPercent)

        if leverage <= 0 {
            blockedReason = "자동매매 레버리지는 1x 이상이어야 합니다."
            positionMarginRatio = 0
            accountRiskPercent = 0
        } else if leverage > maximumAutoTradingLeverage {
            blockedReason = "자동매매 레버리지는 최대 \(maximumAutoTradingLeverage)x까지만 허용됩니다."
            positionMarginRatio = 0
            accountRiskPercent = 0
        } else if signal.hasValidPriceLayout == false {
            blockedReason = "진입가, 손절가, 익절가 방향이 맞지 않아 신호를 제외했습니다."
            positionMarginRatio = 0
            accountRiskPercent = 0
        } else if let ratio = signal.plannedRewardRiskRatio,
                  ratio < minimumRewardRiskRatio {
            blockedReason = "손익비가 \(minimumRewardRiskRatio.riskText):1 미만이라 신호를 제외했습니다. 현재 \(ratio.riskText):1"
            positionMarginRatio = 0
            accountRiskPercent = 0
        } else if signal.plannedRewardRiskRatio == nil {
            blockedReason = "손익비를 계산할 수 없어 신호를 제외했습니다."
            positionMarginRatio = 0
            accountRiskPercent = 0
        } else if let fullMarginRisk = signal.leveragedStopLossPercent(leverage: leverage),
                  fullMarginRisk > 0 {
            positionMarginRatio = sizedPositionMarginRatio(
                fullMarginRiskPercent: fullMarginRisk,
                maximumRiskPerTradePercent: riskLimit,
                maximumPositionMarginPercent: positionMarginLimit
            )
            accountRiskPercent = fullMarginRisk * positionMarginRatio

            if let leveragedReward = signal.leveragedSplitTakeProfitPercent(leverage: leverage) {
                let scaledReward = leveragedReward * positionMarginRatio
                let takeProfitFee = TradingFeePolicy.marketEntryTakeProfitLimitFeePercent(
                    leverage: leverage,
                    positionMarginRatio: positionMarginRatio
                )
                blockedReason = scaledReward <= takeProfitFee
                    ? "익절 기대 수익이 진입 시장가와 익절 예약 주문 수수료보다 작거나 같아 제외했습니다. 익절 \(scaledReward.riskText)%, 수수료 \(takeProfitFee.riskText)%"
                    : nil
            } else {
                blockedReason = "익절 기대 수익을 계산할 수 없어 신호를 제외했습니다."
            }
        } else if signal.leveragedStopLossPercent(leverage: leverage) == nil {
            blockedReason = "손절 위험을 계산할 수 없어 신호를 제외했습니다."
            positionMarginRatio = 0
            accountRiskPercent = 0
        } else {
            blockedReason = "손절 위험이 0보다 커야 합니다."
            positionMarginRatio = 0
            accountRiskPercent = 0
        }

        return RiskDecision(
            id: UUID(),
            intentID: signal.id,
            isAllowed: blockedReason == nil,
            reason: blockedReason ?? "리스크 기준 통과, 투입비율 \((positionMarginRatio * 100).riskText)%, 계좌 손실위험 \(accountRiskPercent.riskText)%",
            positionMarginRatio: positionMarginRatio,
            accountRiskPercent: accountRiskPercent,
            decidedAt: decidedAt
        )
    }

    static func clampedMaximumRiskPerTradePercent(_ value: Decimal) -> Decimal {
        min(
            max(value, minimumConfigurableRiskPerTradePercent),
            maximumConfigurableRiskPerTradePercent
        )
    }

    static func clampedMaximumPositionMarginPercent(_ value: Decimal) -> Decimal {
        min(
            max(value, minimumConfigurablePositionMarginPercent),
            maximumConfigurablePositionMarginPercent
        )
    }

    private static func sizedPositionMarginRatio(
        fullMarginRiskPercent: Decimal,
        maximumRiskPerTradePercent: Decimal,
        maximumPositionMarginPercent: Decimal
    ) -> Decimal {
        guard fullMarginRiskPercent > 0 else { return 0 }
        return min(
            maximumPositionMarginPercent / 100,
            maximumRiskPerTradePercent / fullMarginRiskPercent
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

    var partialTakeProfit: Decimal {
        (entryPrice + takeProfit) / 2
    }

    var profitLockStopLossAfterPartialTakeProfit: Decimal {
        entryPrice + (takeProfit - entryPrice) * SplitTakeProfitPlan.profitLockStopRatio
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

    func leveragedSplitTakeProfitPercent(leverage: Int) -> Decimal? {
        guard entryPrice > 0, hasValidPriceLayout else { return nil }
        let firstReward = absoluteDecimal(partialTakeProfit - entryPrice)
        let finalReward = absoluteDecimal(takeProfit - entryPrice)
        let blendedReward = firstReward * SplitTakeProfitPlan.partialTakeProfitRatio +
            finalReward * SplitTakeProfitPlan.finalTakeProfitRatio
        return blendedReward / entryPrice * 100 * Decimal(leverage)
    }
}

enum SplitTakeProfitPlan {
    static let partialTakeProfitRatio: Decimal = Decimal(5) / Decimal(10)
    static let finalTakeProfitRatio: Decimal = Decimal(5) / Decimal(10)
    static let profitLockStopRatio: Decimal = Decimal(25) / Decimal(100)
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
