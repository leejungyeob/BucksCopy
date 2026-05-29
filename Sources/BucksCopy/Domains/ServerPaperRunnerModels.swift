import Foundation

struct ServerRunnerConfiguration: Equatable, Codable {
    let endpoint: String
    let authToken: String?
    let authenticatedUserID: String?
    let redactedCredentialIdentifier: String?

    init(
        endpoint: String,
        authToken: String?,
        authenticatedUserID: String? = nil,
        redactedCredentialIdentifier: String? = nil
    ) {
        self.endpoint = endpoint
        let trimmedToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authToken = trimmedToken?.isEmpty == false ? trimmedToken : nil
        let trimmedUserID = authenticatedUserID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authenticatedUserID = trimmedUserID?.isEmpty == false ? trimmedUserID : nil
        let trimmedIdentifier = redactedCredentialIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.redactedCredentialIdentifier = trimmedIdentifier?.isEmpty == false ? trimmedIdentifier : nil
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

struct ServerRunnerLoginSession: Equatable {
    let userID: String
    let authToken: String
    let redactedIdentifier: String
    let accounts: [AccountSnapshot]
    let updatedAt: Date?
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
    func loginWithBitgetCredential(_ credential: APIKeyCredential) async throws -> ServerRunnerLoginSession
    func fetchStatus() async throws -> ServerPaperRunnerStatus
    func fetchLogs(limit: Int) async throws -> [TradeEventLog]
    func updateControl(enabled: Bool) async throws -> ServerPaperRunnerControl
}
