import Foundation
@testable import BucksCopy

struct RecordedLeverageRequest: Equatable {
    let symbol: FuturesSymbol
    let leverage: Int
    let marginCoin: String
}

final class TestLiveOrderClient: LiveOrderPlacing, LiveLeverageSetting, ExchangeProtectionOrderPlacing {
    private(set) var leverageRequests: [RecordedLeverageRequest] = []
    private(set) var marketOrders: [LiveOrderRequest] = []
    private(set) var closeRequests: [(symbol: FuturesSymbol, holdSide: PositionSide?)] = []
    private(set) var protectionOrders: [ExchangeProtectionOrder] = []

    func setLeverage(symbol: FuturesSymbol, leverage: Int, marginCoin: String) async throws {
        leverageRequests.append(RecordedLeverageRequest(
            symbol: symbol,
            leverage: leverage,
            marginCoin: marginCoin
        ))
    }

    func placeMarketOrder(_ request: LiveOrderRequest) async throws -> LiveOrderReceipt {
        marketOrders.append(request)
        return LiveOrderReceipt(
            orderID: "entry-\(marketOrders.count)",
            clientOid: request.clientOid,
            symbol: request.symbol,
            status: .filled,
            filledSize: request.size,
            averagePrice: nil
        )
    }

    func closePosition(
        symbol: FuturesSymbol,
        holdSide: PositionSide?
    ) async throws -> LiveClosePositionReceipt {
        closeRequests.append((symbol: symbol, holdSide: holdSide))
        return LiveClosePositionReceipt(
            symbol: symbol,
            orderIDs: ["close-\(closeRequests.count)"]
        )
    }

    func placeProtectionOrder(_ order: ExchangeProtectionOrder) async throws -> ExchangeProtectionReceipt {
        protectionOrders.append(order)
        return ExchangeProtectionReceipt(
            orderID: "protection-\(protectionOrders.count)",
            clientOid: order.clientOid,
            kind: order.kind,
            attempts: 1
        )
    }
}
