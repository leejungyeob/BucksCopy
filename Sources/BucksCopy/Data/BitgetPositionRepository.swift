import Foundation

final class BitgetPositionRepository: PositionRepository, PositionProtectionRepository {
    private let client: BitgetRESTClient

    init(client: BitgetRESTClient) {
        self.client = client
    }

    func fetchPositions() async throws -> [PositionSnapshot] {
        let dtos: [BitgetPositionDTO] = try await client.sendSignedGET(
            path: "/api/v2/mix/position/all-position",
            queryItems: [
                URLQueryItem(name: "marginCoin", value: "USDT"),
                URLQueryItem(name: "productType", value: ProductType.usdtFutures.rawValue)
            ]
        )
        return dtos.map(\.domain)
    }

    func fetchPendingPositionProtectionOrders() async throws -> [PositionProtectionOrderSnapshot] {
        let response: BitgetPendingPlanOrdersResponseDTO = try await client.sendSignedGET(
            path: "/api/v2/mix/order/orders-plan-pending",
            queryItems: [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "planType", value: "profit_loss"),
                URLQueryItem(name: "productType", value: ProductType.usdtFutures.rawValue)
            ]
        )
        return response.entrustedList.compactMap(\.domain)
    }
}

struct BitgetPositionDTO: Decodable, Equatable {
    let symbol: String
    let marginCoin: String?
    let holdSide: String?
    let available: String?
    let total: String?
    let leverage: String?
    let openPriceAvg: String?
    let marginMode: String?
    let posMode: String?
    let unrealizedPL: String?
    let liquidationPrice: String?
    let markPrice: String?
    let takeProfit: String?
    let stopLoss: String?
    let cTime: String?
    let uTime: String?

    private enum CodingKeys: String, CodingKey {
        case symbol
        case instId
        case marginCoin
        case holdSide
        case available
        case total
        case leverage
        case openPriceAvg
        case marginMode
        case posMode
        case unrealizedPL
        case liquidationPrice
        case markPrice
        case takeProfit
        case stopLoss
        case cTime
        case uTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = Self.stringValue(container, forKey: .symbol)
            ?? Self.stringValue(container, forKey: .instId)
            ?? ""
        marginCoin = Self.stringValue(container, forKey: .marginCoin)
        holdSide = Self.stringValue(container, forKey: .holdSide)
        available = Self.stringValue(container, forKey: .available)
        total = Self.stringValue(container, forKey: .total)
        leverage = Self.stringValue(container, forKey: .leverage)
        openPriceAvg = Self.stringValue(container, forKey: .openPriceAvg)
        marginMode = Self.stringValue(container, forKey: .marginMode)
        posMode = Self.stringValue(container, forKey: .posMode)
        unrealizedPL = Self.stringValue(container, forKey: .unrealizedPL)
        liquidationPrice = Self.stringValue(container, forKey: .liquidationPrice)
        markPrice = Self.stringValue(container, forKey: .markPrice)
        takeProfit = Self.stringValue(container, forKey: .takeProfit)
        stopLoss = Self.stringValue(container, forKey: .stopLoss)
        cTime = Self.stringValue(container, forKey: .cTime)
        uTime = Self.stringValue(container, forKey: .uTime)
    }

    var domain: PositionSnapshot {
        PositionSnapshot(
            symbol: FuturesSymbol(symbol),
            side: PositionSide(rawValue: holdSide ?? "") ?? .unknown,
            total: DecimalText.parse(total),
            available: DecimalText.parse(available),
            openPriceAverage: DecimalText.parse(openPriceAvg),
            markPrice: DecimalText.parse(markPrice),
            unrealizedProfitLoss: DecimalText.parse(unrealizedPL),
            leverage: Int(leverage ?? "") ?? 0,
            marginMode: marginMode ?? "",
            positionMode: PositionMode(rawValue: posMode ?? "") ?? .unknown,
            liquidationPrice: DecimalText.optional(liquidationPrice),
            takeProfit: DecimalText.optional(takeProfit),
            stopLoss: DecimalText.optional(stopLoss),
            createdAt: Self.date(millisecondsText: cTime),
            updatedAt: Self.date(millisecondsText: uTime)
        )
    }

    private static func date(millisecondsText: String?) -> Date? {
        millisecondsText.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    private static func stringValue(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}

struct BitgetPendingPlanOrdersResponseDTO: Decodable, Equatable {
    let entrustedList: [BitgetPendingPlanOrderDTO]
    let endId: String?
}

struct BitgetPendingPlanOrderDTO: Decodable, Equatable {
    let planType: String?
    let symbol: String?
    let size: String?
    let orderId: String?
    let executePrice: String?
    let triggerPrice: String?
    let posSide: String?
    let orderSource: String?
    let cTime: String?
    let uTime: String?
    let stopSurplusExecutePrice: String?
    let stopSurplusTriggerPrice: String?
    let stopLossExecutePrice: String?
    let stopLossTriggerPrice: String?

    private enum CodingKeys: String, CodingKey {
        case planType
        case symbol
        case size
        case orderId
        case executePrice
        case triggerPrice
        case posSide
        case orderSource
        case cTime
        case uTime
        case stopSurplusExecutePrice
        case stopSurplusTriggerPrice
        case stopLossExecutePrice
        case stopLossTriggerPrice
    }

    var domain: PositionProtectionOrderSnapshot? {
        guard let symbol, !symbol.isEmpty,
              let kind = protectionKind,
              let triggerPrice = protectionTriggerPrice,
              triggerPrice > 0 else {
            return nil
        }

        return PositionProtectionOrderSnapshot(
            symbol: FuturesSymbol(symbol.uppercased()),
            side: PositionSide(rawValue: posSide ?? "") ?? .unknown,
            kind: kind,
            triggerPrice: triggerPrice,
            executePrice: protectionExecutePrice,
            size: DecimalText.parse(size),
            orderID: orderId ?? "",
            updatedAt: Self.date(millisecondsText: uTime) ?? Self.date(millisecondsText: cTime)
        )
    }

    private var protectionKind: ExchangeProtectionOrderKind? {
        let orderSourceText = (orderSource ?? "").lowercased()
        if orderSourceText.contains("loss") || stopLossTriggerPrice?.isEmpty == false {
            return .stopLoss
        }
        if orderSourceText.contains("profit") ||
            orderSourceText.contains("surplus") ||
            stopSurplusTriggerPrice?.isEmpty == false {
            return .takeProfit
        }

        let planText = (planType ?? "").lowercased()
        if planText.contains("loss"), planText.contains("profit") == false {
            return .stopLoss
        }
        if planText.contains("profit"), planText.contains("loss") == false {
            return .takeProfit
        }
        return nil
    }

    private var protectionTriggerPrice: Decimal? {
        switch protectionKind {
        case .takeProfit:
            return DecimalText.optional(triggerPrice) ??
                DecimalText.optional(stopSurplusTriggerPrice)
        case .stopLoss:
            return DecimalText.optional(triggerPrice) ??
                DecimalText.optional(stopLossTriggerPrice)
        case nil:
            return nil
        }
    }

    private var protectionExecutePrice: Decimal? {
        switch protectionKind {
        case .takeProfit:
            return DecimalText.optional(executePrice) ??
                DecimalText.optional(stopSurplusExecutePrice)
        case .stopLoss:
            return DecimalText.optional(executePrice) ??
                DecimalText.optional(stopLossExecutePrice)
        case nil:
            return nil
        }
    }

    private static func date(millisecondsText: String?) -> Date? {
        millisecondsText.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
