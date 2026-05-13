import Foundation

final class BitgetPositionRepository: PositionRepository {
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
