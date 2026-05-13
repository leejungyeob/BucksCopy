import Foundation

final class DisabledLiveOrderClient: LiveOrderPlacing {
    private(set) var attemptedOrderCount = 0

    func placeLiveOrder(_ intent: OrderIntent) async throws {
        attemptedOrderCount += 1
        throw TradingDomainError.liveTradingDisabled
    }
}
