import Foundation

enum ServerPaperRunnerClientError: Error, Equatable {
    case invalidURL
    case httpStatus(Int)
    case emptyResponse
}

final class ServerPaperRunnerHTTPClient: ServerPaperRunnerService {
    private let baseURL: URL
    private let authToken: String?
    private let session: URLSession
    private let decoder = JSONDecoder()

    var endpointText: String {
        baseURL.absoluteString
    }

    init(baseURL: URL, authToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        let normalizedToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authToken = normalizedToken?.isEmpty == false ? normalizedToken : nil
        self.session = session
    }

    func loginWithBitgetCredential(_ credential: APIKeyCredential) async throws -> ServerRunnerLoginSession {
        let body = try JSONEncoder().encode(LoginRequestDTO(
            apiKey: credential.apiKey,
            secretKey: credential.secretKey,
            passphrase: credential.passphrase
        ))
        let data = try await request(
            path: "auth/bitget/login",
            method: "POST",
            body: body,
            headers: ["Content-Type": "application/json"]
        )
        return try decoder.decode(LoginResponseDTO.self, from: data).domain
    }

    func fetchStatus() async throws -> ServerPaperRunnerStatus {
        let data = try await request(path: "users/me/status")
        return try decoder.decode(StatusDTO.self, from: data).domain
    }

    func fetchLogs(limit: Int) async throws -> [TradeEventLog] {
        let data = try await request(path: "users/me/logs", queryItems: [
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 500))))
        ])
        return try decoder.decode(LogsDTO.self, from: data).items.map(\.domain)
    }

    func updateControl(enabled: Bool) async throws -> ServerPaperRunnerControl {
        let body = try JSONEncoder().encode(ControlUpdateDTO(enabled: enabled))
        let data = try await request(
            path: "users/me/control",
            method: "POST",
            body: body,
            headers: ["Content-Type": "application/json"]
        )
        return try decoder.decode(ControlDTO.self, from: data).domain
    }

    private func request(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw ServerPaperRunnerClientError.invalidURL
        }
        if queryItems.isEmpty == false {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw ServerPaperRunnerClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServerPaperRunnerClientError.emptyResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ServerPaperRunnerClientError.httpStatus(httpResponse.statusCode)
        }
        guard data.isEmpty == false else {
            throw ServerPaperRunnerClientError.emptyResponse
        }
        return data
    }
}

private struct LoginRequestDTO: Encodable {
    let apiKey: String
    let secretKey: String
    let passphrase: String
}

private struct LoginResponseDTO: Decodable {
    let authToken: String
    let userID: String
    let redactedIdentifier: String
    let accounts: [AccountDTO]?
    let updatedAt: String?

    var domain: ServerRunnerLoginSession {
        ServerRunnerLoginSession(
            userID: userID,
            authToken: authToken,
            redactedIdentifier: redactedIdentifier,
            accounts: (accounts ?? []).map(\.domain),
            updatedAt: ServerRunnerDateParser.date(from: updatedAt)
        )
    }
}

private struct AccountDTO: Decodable {
    let marginCoin: String?
    let available: String?
    let accountEquity: String?
    let unrealizedPL: String?
    let updatedAt: String?

    var domain: AccountSnapshot {
        AccountSnapshot(
            marginCoin: marginCoin ?? "USDT",
            available: DecimalText.parse(available),
            accountEquity: DecimalText.parse(accountEquity),
            unrealizedProfitLoss: DecimalText.parse(unrealizedPL),
            updatedAt: ServerRunnerDateParser.date(from: updatedAt) ?? Date()
        )
    }
}

private struct ControlUpdateDTO: Encodable {
    let enabled: Bool
}

private struct ControlDTO: Decodable {
    let enabled: Bool
    let mode: String
    let updatedAt: String?
    let updatedBy: String?

    var domain: ServerPaperRunnerControl {
        ServerPaperRunnerControl(
            enabled: enabled,
            mode: mode,
            updatedAt: ServerRunnerDateParser.date(from: updatedAt),
            updatedBy: updatedBy
        )
    }
}

private struct StatusDTO: Decodable {
    let updatedAt: String?
    let mode: String
    let symbols: [String]
    let latestClosedCandleOpenTime: Int?
    let latestClosedCandleOpenTimeISO: String?
    let savedCandles: Int
    let evaluations: Int
    let skippedEvaluations: Int?
    let signals: Int
    let failures: [String]
    let storagePath: String?
    let control: ControlDTO?

    var domain: ServerPaperRunnerStatus {
        ServerPaperRunnerStatus(
            updatedAt: ServerRunnerDateParser.date(from: updatedAt),
            mode: mode,
            symbols: symbols,
            latestClosedCandleOpenTime: latestClosedCandleOpenTime,
            latestClosedCandleOpenTimeDate: ServerRunnerDateParser.date(from: latestClosedCandleOpenTimeISO),
            savedCandles: savedCandles,
            evaluations: evaluations,
            skippedEvaluations: skippedEvaluations ?? 0,
            signals: signals,
            failures: failures,
            storagePath: storagePath,
            control: control?.domain
        )
    }
}

private struct LogsDTO: Decodable {
    let items: [LogDTO]
}

private struct LogDTO: Decodable {
    let id: UUID?
    let timestamp: String
    let category: String
    let severity: String?
    let symbol: String?
    let message: String
    let metadata: LogMetadataDTO?

    var domain: TradeEventLog {
        TradeEventLog(
            id: id ?? UUID(),
            timestamp: ServerRunnerDateParser.date(from: timestamp) ?? Date(),
            category: TradeEventCategory(rawValue: category) ?? .bot,
            severity: severity.flatMap(TradeEventSeverity.init(rawValue:)) ?? .info,
            symbol: symbol.map(FuturesSymbol.init),
            message: message,
            metadata: metadata?.domain
        )
    }
}

private struct LogMetadataDTO: Decodable {
    let title: String?
    let subtitle: String?
    let tags: [String]
    let details: [String: String]

    enum CodingKeys: String, CodingKey {
        case title
        case subtitle
        case tags
        case details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        details = (try? container.decode([String: String].self, forKey: .details)) ?? [:]
    }

    var domain: TradeLogMetadata? {
        let resolvedTitle = title ?? "Server runner"
        return TradeLogMetadata(
            title: resolvedTitle,
            subtitle: subtitle,
            tags: tags.map { TradeLogTag(label: $0) },
            details: details
                .sorted { $0.key < $1.key }
                .map { TradeLogDetail(label: $0.key, value: $0.value) }
        )
    }
}

private enum ServerRunnerDateParser {
    static func date(from text: String?) -> Date? {
        guard let text, text.isEmpty == false else { return nil }
        if let date = fractionalFormatter.date(from: text) {
            return date
        }
        return plainFormatter.date(from: text)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
