import Foundation

enum TradingFeePolicy {
    static let futuresTakerFeeRate: Decimal = Decimal(6) / Decimal(10_000)
    static let referralRegisteredDiscountRate: Decimal = Decimal(2) / Decimal(10)
    static let referralRegisteredFuturesTakerFeeRate: Decimal = futuresTakerFeeRate * (1 - referralRegisteredDiscountRate)

    static func roundTripTakerFeePercent(leverage: Int) -> Decimal {
        guard leverage > 0 else { return 0 }
        return referralRegisteredFuturesTakerFeeRate * Decimal(2) * Decimal(leverage) * 100
    }

    static func netLeveragedReturnPercent(
        grossLeveragedReturnPercent: Decimal,
        leverage: Int
    ) -> Decimal {
        grossLeveragedReturnPercent - roundTripTakerFeePercent(leverage: leverage)
    }
}
