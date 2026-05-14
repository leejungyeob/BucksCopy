import Foundation

enum BitgetClientError: Error, Equatable {
    case missingCredential
    case invalidURL
    case httpStatus(Int)
    case apiError(code: String, message: String)
    case emptyData
}

extension BitgetClientError: PublicTradingErrorDescribing {
    var tradingLogDescription: String {
        switch self {
        case .missingCredential:
            return "Bitget credential missing"
        case .invalidURL:
            return "Bitget request URL invalid"
        case .httpStatus(let status):
            return "Bitget HTTP \(status)"
        case .apiError(let code, let message):
            return "Bitget API \(code): \(message)"
        case .emptyData:
            return "Bitget empty response"
        }
    }
}

final class BitgetRESTClient {
    private let baseURL: URL
    private let session: URLSession
    private let credentialStore: CredentialStore
    private let signer: BitgetRequestSigner
    private let clock: Clock

    init(
        baseURL: URL = URL(string: "https://api.bitget.com")!,
        session: URLSession = .shared,
        credentialStore: CredentialStore,
        signer: BitgetRequestSigner = BitgetRequestSigner(),
        clock: Clock = SystemClock()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.credentialStore = credentialStore
        self.signer = signer
        self.clock = clock
    }

    func sendSignedGET<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> Response {
        guard let credential = try credentialStore.load(), credential.isComplete else {
            throw BitgetClientError.missingCredential
        }

        let sortedItems = queryItems.sorted { $0.name < $1.name }
        let queryString = Self.queryString(from: sortedItems)
        guard let url = Self.url(baseURL: baseURL, path: path, queryItems: sortedItems) else {
            throw BitgetClientError.invalidURL
        }

        let timestamp = String(Int(clock.now.timeIntervalSince1970 * 1000))
        let signature = signer.sign(
            timestamp: timestamp,
            method: "GET",
            requestPath: path,
            queryString: queryString,
            body: "",
            secretKey: credential.secretKey
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(credential.apiKey, forHTTPHeaderField: "ACCESS-KEY")
        request.addValue(signature, forHTTPHeaderField: "ACCESS-SIGN")
        request.addValue(credential.passphrase, forHTTPHeaderField: "ACCESS-PASSPHRASE")
        request.addValue(timestamp, forHTTPHeaderField: "ACCESS-TIMESTAMP")
        request.addValue("en-US", forHTTPHeaderField: "locale")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw BitgetClientError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw BitgetClientError.emptyData
        }

        let decoded = try JSONDecoder().decode(BitgetResponse<Response>.self, from: data)
        guard decoded.code == "00000" else {
            throw BitgetClientError.apiError(code: decoded.code, message: decoded.msg)
        }
        return decoded.data
    }

    func sendSignedPOST<Response: Decodable, Body: Encodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        guard let credential = try credentialStore.load(), credential.isComplete else {
            throw BitgetClientError.missingCredential
        }
        guard let url = Self.url(baseURL: baseURL, path: path, queryItems: []) else {
            throw BitgetClientError.invalidURL
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData = try encoder.encode(body)
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
        let timestamp = String(Int(clock.now.timeIntervalSince1970 * 1000))
        let signature = signer.sign(
            timestamp: timestamp,
            method: "POST",
            requestPath: path,
            queryString: "",
            body: bodyString,
            secretKey: credential.secretKey
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.addValue(credential.apiKey, forHTTPHeaderField: "ACCESS-KEY")
        request.addValue(signature, forHTTPHeaderField: "ACCESS-SIGN")
        request.addValue(credential.passphrase, forHTTPHeaderField: "ACCESS-PASSPHRASE")
        request.addValue(timestamp, forHTTPHeaderField: "ACCESS-TIMESTAMP")
        request.addValue("en-US", forHTTPHeaderField: "locale")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw BitgetClientError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw BitgetClientError.emptyData
        }

        let decoded = try JSONDecoder().decode(BitgetResponse<Response>.self, from: data)
        guard decoded.code == "00000" else {
            throw BitgetClientError.apiError(code: decoded.code, message: decoded.msg)
        }
        return decoded.data
    }

    func sendPublicGET<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> Response {
        let sortedItems = queryItems.sorted { $0.name < $1.name }
        guard let url = Self.url(baseURL: baseURL, path: path, queryItems: sortedItems) else {
            throw BitgetClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("en-US", forHTTPHeaderField: "locale")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw BitgetClientError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw BitgetClientError.emptyData
        }

        let decoded = try JSONDecoder().decode(BitgetResponse<Response>.self, from: data)
        guard decoded.code == "00000" else {
            throw BitgetClientError.apiError(code: decoded.code, message: decoded.msg)
        }
        return decoded.data
    }

    static func queryString(from queryItems: [URLQueryItem]) -> String {
        queryItems
            .map { item in
                if let value = item.value {
                    return "\(item.name)=\(value)"
                }
                return item.name
            }
            .joined(separator: "&")
    }

    private static func url(baseURL: URL, path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems
        return components?.url
    }
}

private struct BitgetResponse<DataPayload: Decodable>: Decodable {
    let code: String
    let msg: String
    let data: DataPayload
}
