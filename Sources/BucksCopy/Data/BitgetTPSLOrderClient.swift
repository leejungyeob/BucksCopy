import Foundation

final class BitgetTPSLOrderClient: ExchangeProtectionOrderPlacing {
    private let client: BitgetRESTClient

    init(client: BitgetRESTClient) {
        self.client = client
    }

    func placeProtectionOrder(_ order: ExchangeProtectionOrder) async throws -> ExchangeProtectionReceipt {
        let dto = BitgetTPSLOrderRequestDTO(order: order)
        let response: BitgetTPSLOrderResponseDTO = try await client.sendSignedPOST(
            path: "/api/v2/mix/order/place-tpsl-order",
            body: dto
        )
        return ExchangeProtectionReceipt(
            orderID: response.orderId ?? "",
            clientOid: response.clientOid ?? order.clientOid,
            kind: order.kind,
            attempts: 1
        )
    }
}

struct BitgetTPSLOrderRequestDTO: Encodable, Equatable {
    let marginCoin: String
    let productType: String
    let symbol: String
    let planType: String
    let triggerPrice: String
    let triggerType: String
    let executePrice: String
    let holdSide: String
    let size: String
    let rangeRate: String
    let clientOid: String

    init(order: ExchangeProtectionOrder) {
        marginCoin = order.marginCoin
        productType = ProductType.usdtFutures.rawValue
        symbol = order.symbol.rawValue
        planType = order.kind.bitgetPlanType
        triggerPrice = DecimalText.string(order.triggerPrice)
        triggerType = "mark_price"
        executePrice = order.executePrice.map(DecimalText.string) ?? "0"
        holdSide = order.holdSide.bitgetHoldSide
        size = DecimalText.string(order.size)
        rangeRate = ""
        clientOid = order.clientOid
    }
}

struct BitgetTPSLOrderResponseDTO: Decodable, Equatable {
    let orderId: String?
    let clientOid: String?
}

private extension ExchangeProtectionOrderKind {
    var bitgetPlanType: String {
        switch self {
        case .takeProfit:
            return "profit_plan"
        case .stopLoss:
            return "loss_plan"
        }
    }
}

private extension PositionSide {
    var bitgetHoldSide: String {
        switch self {
        case .long:
            return "long"
        case .short:
            return "short"
        case .unknown:
            return ""
        }
    }
}
