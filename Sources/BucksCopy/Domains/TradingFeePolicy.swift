import Foundation

enum TradingFeePolicy {
    static let futuresMakerFeeRate: Decimal = Decimal(2) / Decimal(10_000)
    static let futuresTakerFeeRate: Decimal = Decimal(6) / Decimal(10_000)
    static let referralRegisteredDiscountRate: Decimal = Decimal(2) / Decimal(10)
    static let referralRegisteredFuturesMakerFeeRate: Decimal = futuresMakerFeeRate * (1 - referralRegisteredDiscountRate)
    static let referralRegisteredFuturesTakerFeeRate: Decimal = futuresTakerFeeRate * (1 - referralRegisteredDiscountRate)

    static func marketEntryTakeProfitLimitFeePercent(leverage: Int) -> Decimal {
        leveragedFeePercent(
            entryFeeRate: referralRegisteredFuturesTakerFeeRate,
            exitFeeRate: referralRegisteredFuturesMakerFeeRate,
            leverage: leverage
        )
    }

    static func marketEntryStopLossMarketFeePercent(leverage: Int) -> Decimal {
        leveragedFeePercent(
            entryFeeRate: referralRegisteredFuturesTakerFeeRate,
            exitFeeRate: referralRegisteredFuturesTakerFeeRate,
            leverage: leverage
        )
    }

    static func feePercent(outcome: BacktestTradeOutcome, leverage: Int) -> Decimal {
        switch outcome {
        case .win:
            return marketEntryTakeProfitLimitFeePercent(leverage: leverage)
        case .loss:
            return marketEntryStopLossMarketFeePercent(leverage: leverage)
        }
    }

    static func netLeveragedReturnPercent(
        grossLeveragedReturnPercent: Decimal,
        outcome: BacktestTradeOutcome,
        leverage: Int
    ) -> Decimal {
        grossLeveragedReturnPercent - feePercent(outcome: outcome, leverage: leverage)
    }

    private static func leveragedFeePercent(
        entryFeeRate: Decimal,
        exitFeeRate: Decimal,
        leverage: Int
    ) -> Decimal {
        guard leverage > 0 else { return 0 }
        return (entryFeeRate + exitFeeRate) * Decimal(leverage) * 100
    }
}
