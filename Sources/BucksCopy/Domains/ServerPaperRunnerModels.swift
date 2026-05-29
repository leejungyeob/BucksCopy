import Foundation

struct ServerRunnerConfiguration: Equatable, Codable {
    let endpoint: String
    let authToken: String?

    init(endpoint: String, authToken: String?) {
        self.endpoint = endpoint
        let trimmedToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authToken = trimmedToken?.isEmpty == false ? trimmedToken : nil
    }

    var hasAuthToken: Bool {
        authToken != nil
    }

    var redactedAuthToken: String? {
        guard let authToken else { return nil }
        if authToken.count <= 8 {
            return "****"
        }
        return "\(authToken.prefix(4))...\(authToken.suffix(4))"
    }
}

struct ServerPaperRunnerControl: Equatable {
    let enabled: Bool
    let mode: String
    let updatedAt: Date?
    let updatedBy: String?
}

struct ServerPaperRunnerStatus: Equatable {
    let updatedAt: Date?
    let mode: String
    let symbols: [String]
    let latestClosedCandleOpenTime: Int?
    let latestClosedCandleOpenTimeDate: Date?
    let savedCandles: Int
    let evaluations: Int
    let skippedEvaluations: Int
    let signals: Int
    let failures: [String]
    let storagePath: String?
    let control: ServerPaperRunnerControl?
}

enum ServerRunnerConnectionState: Equatable {
    case idle
    case refreshing
    case connected(checkedAt: Date)
    case failed(message: String)
}

protocol ServerPaperRunnerService {
    func fetchStatus() async throws -> ServerPaperRunnerStatus
    func fetchLogs(limit: Int) async throws -> [TradeEventLog]
    func updateControl(enabled: Bool) async throws -> ServerPaperRunnerControl
}
