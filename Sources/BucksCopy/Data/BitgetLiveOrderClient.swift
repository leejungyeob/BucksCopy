import Foundation

final class BitgetLiveOrderClient: LiveOrderPlacing, LiveLeverageSetting {
    private let client: BitgetRESTClient
    private let confirmationAttempts: Int
    private let confirmationDelayNanoseconds: UInt64

    init(
        client: BitgetRESTClient,
        confirmationAttempts: Int = 8,
        confirmationDelayNanoseconds: UInt64 = 350_000_000
    ) {
        self.client = client
        self.confirmationAttempts = confirmationAttempts
        self.confirmationDelayNanoseconds = confirmationDelayNanoseconds
    }

    func setLeverage(
        symbol: FuturesSymbol,
        leverage: Int,
        marginCoin: String,
        holdSide: PositionSide?
    ) async throws {
        let body = BitgetSetLeverageRequestDTO(
            symbol: symbol.rawValue,
            productType: ProductType.usdtFutures.rawValue,
            marginCoin: marginCoin.uppercased(),
            leverage: String(leverage),
            holdSide: holdSide?.bitgetClosePositionHoldSide
        )
        let _: BitgetSetLeverageResponseDTO = try await client.sendSignedPOST(
            path: "/api/v2/mix/account/set-leverage",
            body: body
        )
    }

    func placeMarketOrder(_ request: LiveOrderRequest) async throws -> LiveOrderReceipt {
        let body = BitgetPlaceOrderRequestDTO(request: request)
        let response: BitgetPlaceOrderResponseDTO = try await client.sendSignedPOST(
            path: "/api/v2/mix/order/place-order",
            body: body
        )

        return try await confirmFilledOrder(
            symbol: request.symbol,
            orderID: response.orderId,
            clientOid: response.clientOid ?? request.clientOid
        )
    }

    func closePosition(
        symbol: FuturesSymbol,
        holdSide: PositionSide?
    ) async throws -> LiveClosePositionReceipt {
        let body = BitgetClosePositionRequestDTO(
            symbol: symbol.rawValue,
            productType: ProductType.usdtFutures.rawValue,
            holdSide: holdSide?.bitgetClosePositionHoldSide
        )
        let response: BitgetClosePositionResponseDTO = try await client.sendSignedPOST(
            path: "/api/v2/mix/order/close-positions",
            body: body
        )

        if let failure = response.failureList.first {
            throw BitgetClientError.apiError(
                code: failure.errorCode ?? "close-position-failed",
                message: failure.errorMsg ?? "close position failed"
            )
        }

        return LiveClosePositionReceipt(
            symbol: symbol,
            orderIDs: response.successList.map(\.orderId)
        )
    }

    private func confirmFilledOrder(
        symbol: FuturesSymbol,
        orderID: String?,
        clientOid: String
    ) async throws -> LiveOrderReceipt {
        var latestReceipt = LiveOrderReceipt(
            orderID: orderID ?? "",
            clientOid: clientOid,
            symbol: symbol,
            status: .unknown,
            filledSize: nil,
            averagePrice: nil
        )

        for attempt in 0..<confirmationAttempts {
            if attempt > 0, confirmationDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: confirmationDelayNanoseconds)
            }

            let detail = try await fetchOrderDetail(
                symbol: symbol,
                orderID: orderID,
                clientOid: clientOid
            )
            latestReceipt = detail.receipt(symbol: symbol, fallbackClientOid: clientOid)
            if latestReceipt.status == .filled {
                return latestReceipt
            }
        }

        return latestReceipt
    }

    private func fetchOrderDetail(
        symbol: FuturesSymbol,
        orderID: String?,
        clientOid: String
    ) async throws -> BitgetOrderDetailDTO {
        var queryItems = [
            URLQueryItem(name: "clientOid", value: clientOid),
            URLQueryItem(name: "productType", value: ProductType.usdtFutures.rawValue),
            URLQueryItem(name: "symbol", value: symbol.rawValue)
        ]
        if let orderID, !orderID.isEmpty {
            queryItems.append(URLQueryItem(name: "orderId", value: orderID))
        }

        return try await client.sendSignedGET(
            path: "/api/v2/mix/order/detail",
            queryItems: queryItems
        )
    }
}

struct BitgetSetLeverageRequestDTO: Encodable, Equatable {
    let symbol: String
    let productType: String
    let marginCoin: String
    let leverage: String
    let holdSide: String?
}

struct BitgetSetLeverageResponseDTO: Decodable, Equatable {
    let symbol: String?
    let marginCoin: String?
    let longLeverage: String?
    let shortLeverage: String?
    let crossMarginLeverage: String?
    let marginMode: String?
}

struct BitgetPlaceOrderRequestDTO: Encodable, Equatable {
    let symbol: String
    let productType: String
    let marginMode: String
    let marginCoin: String
    let size: String
    let side: String
    let tradeSide: String
    let orderType: String
    let clientOid: String
    let reduceOnly: String?

    init(request: LiveOrderRequest) {
        symbol = request.symbol.rawValue
        productType = ProductType.usdtFutures.rawValue
        marginMode = request.marginMode
        marginCoin = request.marginCoin.uppercased()
        size = DecimalText.string(request.size)
        side = request.side.rawValue
        tradeSide = request.purpose.rawValue
        orderType = "market"
        clientOid = request.clientOid
        reduceOnly = request.reduceOnly ? "YES" : nil
    }
}

struct BitgetPlaceOrderResponseDTO: Decodable, Equatable {
    let orderId: String?
    let clientOid: String?
}

struct BitgetOrderDetailDTO: Decodable, Equatable {
    let orderId: String?
    let clientOid: String?
    let state: String?
    let status: String?
    let baseVolume: String?
    let size: String?
    let priceAvg: String?

    func receipt(
        symbol: FuturesSymbol,
        fallbackClientOid: String
    ) -> LiveOrderReceipt {
        LiveOrderReceipt(
            orderID: orderId ?? "",
            clientOid: clientOid ?? fallbackClientOid,
            symbol: symbol,
            status: LiveOrderStatus(bitgetState: state ?? status),
            filledSize: DecimalText.optional(baseVolume) ?? DecimalText.optional(size),
            averagePrice: DecimalText.optional(priceAvg)
        )
    }
}

struct BitgetClosePositionRequestDTO: Encodable, Equatable {
    let symbol: String
    let productType: String
    let holdSide: String?
}

struct BitgetClosePositionResponseDTO: Decodable, Equatable {
    let successList: [BitgetClosePositionSuccessDTO]
    let failureList: [BitgetClosePositionFailureDTO]
}

struct BitgetClosePositionSuccessDTO: Decodable, Equatable {
    let orderId: String
    let clientOid: String?
    let symbol: String
}

struct BitgetClosePositionFailureDTO: Decodable, Equatable {
    let orderId: String?
    let clientOid: String?
    let symbol: String?
    let errorMsg: String?
    let errorCode: String?
}

private extension PositionSide {
    var bitgetClosePositionHoldSide: String? {
        switch self {
        case .long:
            return "long"
        case .short:
            return "short"
        case .unknown:
            return nil
        }
    }
}

private extension LiveOrderStatus {
    init(bitgetState: String?) {
        switch bitgetState?.lowercased() {
        case "live", "new", "init":
            self = .live
        case "partially_filled", "partial-fill", "partial_filled":
            self = .partiallyFilled
        case "filled", "full-fill", "full_filled":
            self = .filled
        case "canceled", "cancelled":
            self = .canceled
        default:
            self = .unknown
        }
    }
}
