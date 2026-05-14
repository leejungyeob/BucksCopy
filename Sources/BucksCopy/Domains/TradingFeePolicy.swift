import Foundation

enum TradingFeePolicy {
    static let futuresMakerFeeRate: Decimal = Decimal(2) / Decimal(10_000)
    static let futuresTakerFeeRate: Decimal = Decimal(6) / Decimal(10_000)
    static let referralRegisteredDiscountRate: Decimal = Decimal(2) / Decimal(10)
    static let referralRegisteredFuturesMakerFeeRate: Decimal = futuresMakerFeeRate * (1 - referralRegisteredDiscountRate)
    static let referralRegisteredFuturesTakerFeeRate: Decimal = futuresTakerFeeRate * (1 - referralRegisteredDiscountRate)

    static func marketEntryTakeProfitLimitFeePercent(
        leverage: Int,
        positionMarginRatio: Decimal = 1
    ) -> Decimal {
        leveragedFeePercent(
            entryFeeRate: referralRegisteredFuturesTakerFeeRate,
            exitFeeRate: referralRegisteredFuturesMakerFeeRate,
            leverage: leverage,
            positionMarginRatio: positionMarginRatio
        )
    }

    static func marketEntryStopLossMarketFeePercent(
        leverage: Int,
        positionMarginRatio: Decimal = 1
    ) -> Decimal {
        leveragedFeePercent(
            entryFeeRate: referralRegisteredFuturesTakerFeeRate,
            exitFeeRate: referralRegisteredFuturesTakerFeeRate,
            leverage: leverage,
            positionMarginRatio: positionMarginRatio
        )
    }

    static func feePercent(
        outcome: BacktestTradeOutcome,
        leverage: Int,
        positionMarginRatio: Decimal = 1
    ) -> Decimal {
        switch outcome {
        case .win:
            return marketEntryTakeProfitLimitFeePercent(
                leverage: leverage,
                positionMarginRatio: positionMarginRatio
            )
        case .loss:
            return marketEntryStopLossMarketFeePercent(
                leverage: leverage,
                positionMarginRatio: positionMarginRatio
            )
        }
    }

    static func netLeveragedReturnPercent(
        grossLeveragedReturnPercent: Decimal,
        outcome: BacktestTradeOutcome,
        leverage: Int,
        positionMarginRatio: Decimal = 1
    ) -> Decimal {
        grossLeveragedReturnPercent - feePercent(
            outcome: outcome,
            leverage: leverage,
            positionMarginRatio: positionMarginRatio
        )
    }

    private static func leveragedFeePercent(
        entryFeeRate: Decimal,
        exitFeeRate: Decimal,
        leverage: Int,
        positionMarginRatio: Decimal
    ) -> Decimal {
        guard leverage > 0 else { return 0 }
        return (entryFeeRate + exitFeeRate) * Decimal(leverage) * positionMarginRatio * 100
    }
}
