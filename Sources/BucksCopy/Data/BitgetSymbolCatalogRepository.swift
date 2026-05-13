import Foundation

final class BitgetSymbolCatalogRepository: SymbolCatalogRepository {
    private let client: BitgetRESTClient

    init(client: BitgetRESTClient) {
        self.client = client
    }

    func fetchUSDTFuturesSymbols() async throws -> [ContractSpec] {
        let contracts: [BitgetContractConfigDTO] = try await client.sendPublicGET(
            path: "/api/v2/mix/market/contracts",
            queryItems: [
                URLQueryItem(name: "productType", value: ProductType.usdtFutures.rawValue)
            ]
        )

        return contracts
            .compactMap(\.domain)
            .filter(\.isUSDTFuturesTradable)
            .sorted { lhs, rhs in
                let leftRank = Self.priorityRank(lhs.symbol)
                let rightRank = Self.priorityRank(rhs.symbol)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return lhs.symbol.rawValue < rhs.symbol.rawValue
            }
    }

    private static func priorityRank(_ symbol: FuturesSymbol) -> Int {
        let priority = [
            "BTCUSDT", "ETHUSDT", "XRPUSDT", "SOLUSDT", "BNBUSDT", "DOGEUSDT",
            "ADAUSDT", "BCHUSDT", "LTCUSDT", "LINKUSDT", "AVAXUSDT", "TRXUSDT"
        ]
        return priority.firstIndex(of: symbol.rawValue) ?? priority.count
    }
}

struct BitgetContractConfigDTO: Decodable, Equatable {
    let symbol: String
    let baseCoin: String?
    let quoteCoin: String?
    let supportMarginCoins: [String]?
    let minTradeNum: String?
    let minTradeUSDT: String?
    let sizeMultiplier: String?
    let pricePlace: String?
    let volumePlace: String?
    let symbolStatus: String?
    let minLever: String?
    let maxLever: String?

    var domain: ContractSpec? {
        guard !symbol.isEmpty else { return nil }
        return ContractSpec(
            symbol: FuturesSymbol(symbol),
            baseCoin: baseCoin ?? "",
            quoteCoin: quoteCoin ?? "",
            symbolStatus: symbolStatus ?? "",
            supportMarginCoins: supportMarginCoins ?? [],
            minTradeNum: DecimalText.parse(minTradeNum),
            minTradeUSDT: DecimalText.parse(minTradeUSDT),
            sizeMultiplier: DecimalText.parse(sizeMultiplier),
            pricePlace: Int(pricePlace ?? "") ?? 0,
            volumePlace: Int(volumePlace ?? "") ?? 0,
            minLeverage: max(Int(minLever ?? "") ?? 1, 1),
            maxLeverage: max(Int(maxLever ?? "") ?? 1, 1)
        )
    }
}
