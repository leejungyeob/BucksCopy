import Foundation

final class BitgetAccountRepository {
    private let client: BitgetRESTClient

    init(client: BitgetRESTClient) {
        self.client = client
    }

    func fetchAccounts() async throws -> [AccountSnapshot] {
        let dtos: [BitgetAccountDTO] = try await client.sendSignedGET(
            path: "/api/v2/mix/account/accounts",
            queryItems: [
                URLQueryItem(name: "productType", value: ProductType.usdtFutures.rawValue)
            ]
        )
        return dtos.map(\.domain)
    }

    func validateCredentials() async throws {
        _ = try await fetchAccounts()
    }
}

struct BitgetAccountDTO: Decodable, Equatable {
    let marginCoin: String?
    let available: String?
    let accountEquity: String?
    let unrealizedPL: String?

    var domain: AccountSnapshot {
        AccountSnapshot(
            marginCoin: marginCoin ?? "USDT",
            available: DecimalText.parse(available),
            accountEquity: DecimalText.parse(accountEquity),
            unrealizedProfitLoss: DecimalText.parse(unrealizedPL),
            updatedAt: Date()
        )
    }
}
