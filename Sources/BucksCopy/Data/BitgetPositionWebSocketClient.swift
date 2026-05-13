import Foundation

final class BitgetPositionWebSocketClient: PositionStreamService {
    private let url: URL
    private let session: URLSession
    private let credentialStore: CredentialStore
    private let signer: BitgetRequestSigner
    private let clock: Clock
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        url: URL = URL(string: "wss://ws.bitget.com/v2/ws/private")!,
        session: URLSession = .shared,
        credentialStore: CredentialStore,
        signer: BitgetRequestSigner = BitgetRequestSigner(),
        clock: Clock = SystemClock(),
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.url = url
        self.session = session
        self.credentialStore = credentialStore
        self.signer = signer
        self.clock = clock
        self.encoder = encoder
        self.decoder = decoder
    }

    func streamPositions() -> AsyncStream<[PositionSnapshot]> {
        AsyncStream { continuation in
            let streamTask = Task {
                var reconnectDelay: UInt64 = 1_000_000_000

                while !Task.isCancelled {
                    let webSocket = session.webSocketTask(with: url)
                    webSocket.resume()
                    let pingTask = makePingTask(for: webSocket)

                    do {
                        try await login(webSocket)
                        try await subscribePositions(webSocket)
                        reconnectDelay = 1_000_000_000

                        while !Task.isCancelled {
                            let message = try await webSocket.receive()
                            if let positions = try decodePositions(message) {
                                continuation.yield(positions)
                            }
                        }
                    } catch {
                        pingTask.cancel()
                        webSocket.cancel(with: .goingAway, reason: nil)

                        guard !Task.isCancelled else { break }
                        try? await Task.sleep(nanoseconds: reconnectDelay)
                        reconnectDelay = min(reconnectDelay * 2, 10_000_000_000)
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    private func makePingTask(for webSocket: URLSessionWebSocketTask) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                try? await webSocket.send(.string("ping"))
            }
        }
    }

    private func login(_ webSocket: URLSessionWebSocketTask) async throws {
        guard let credential = try credentialStore.load(), credential.isComplete else {
            throw BitgetWebSocketError.missingCredential
        }

        let timestamp = String(Int(clock.now.timeIntervalSince1970 * 1000))
        let request = BitgetWebSocketLoginRequest(
            op: "login",
            args: [
                BitgetWebSocketLoginArg(
                    apiKey: credential.apiKey,
                    passphrase: credential.passphrase,
                    timestamp: timestamp,
                    sign: signer.sign(
                        timestamp: timestamp,
                        method: "GET",
                        requestPath: "/user/verify",
                        queryString: nil,
                        body: "",
                        secretKey: credential.secretKey
                    )
                )
            ]
        )
        try await send(request, to: webSocket)

        while !Task.isCancelled {
            let message = try await webSocket.receive()
            guard let payload = try decodeControlPayload(message) else {
                continue
            }
            if payload.event == "login", payload.code == "0" {
                return
            }
            if payload.event == "error" || payload.code != nil {
                throw BitgetWebSocketError.server(
                    code: payload.code ?? "unknown",
                    message: payload.msg ?? "Bitget private WebSocket login failed"
                )
            }
        }
    }

    private func subscribePositions(_ webSocket: URLSessionWebSocketTask) async throws {
        let request = BitgetPrivateWebSocketSubscriptionRequest(
            op: "subscribe",
            args: [
                BitgetWebSocketChannelArg(
                    instType: ProductType.usdtFutures.rawValue,
                    channel: "positions",
                    instId: "default"
                )
            ]
        )
        try await send(request, to: webSocket)
    }

    private func send<Request: Encodable>(
        _ request: Request,
        to webSocket: URLSessionWebSocketTask
    ) async throws {
        let data = try encoder.encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BitgetWebSocketError.invalidMessage
        }
        try await webSocket.send(.string(text))
    }

    private func decodeControlPayload(
        _ message: URLSessionWebSocketTask.Message
    ) throws -> BitgetWebSocketControlPayload? {
        let data = try data(from: message)
        guard !data.isEmpty else { return nil }
        return try decoder.decode(BitgetWebSocketControlPayload.self, from: data)
    }

    private func decodePositions(
        _ message: URLSessionWebSocketTask.Message
    ) throws -> [PositionSnapshot]? {
        let data = try data(from: message)
        guard !data.isEmpty else { return nil }

        let payload = try decoder.decode(BitgetPositionWebSocketPayload.self, from: data)
        if payload.event == "error" {
            throw BitgetWebSocketError.server(
                code: payload.code ?? "unknown",
                message: payload.msg ?? "Bitget private WebSocket error"
            )
        }

        guard payload.arg?.channel == "positions",
              payload.arg?.instType == ProductType.usdtFutures.rawValue,
              let data = payload.data else {
            return nil
        }
        return data.map(\.domain)
    }

    private func data(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .string(let text):
            guard text != "pong" else { return Data() }
            return Data(text.utf8)
        case .data(let payload):
            return payload
        @unknown default:
            throw BitgetWebSocketError.invalidMessage
        }
    }
}

private struct BitgetWebSocketLoginRequest: Encodable {
    let op: String
    let args: [BitgetWebSocketLoginArg]
}

private struct BitgetWebSocketLoginArg: Encodable {
    let apiKey: String
    let passphrase: String
    let timestamp: String
    let sign: String
}

private struct BitgetPrivateWebSocketSubscriptionRequest: Encodable {
    let op: String
    let args: [BitgetWebSocketChannelArg]
}

private struct BitgetWebSocketControlPayload: Decodable {
    let event: String?
    let code: String?
    let msg: String?
}

struct BitgetPositionWebSocketPayload: Decodable, Equatable {
    let event: String?
    let action: String?
    let arg: BitgetWebSocketChannelArg?
    let data: [BitgetPositionDTO]?
    let code: String?
    let msg: String?
    let ts: Int?
}
