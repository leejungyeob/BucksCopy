import Foundation

enum BitgetWebSocketError: Error, Equatable {
    case missingCredential
    case server(code: String, message: String)
    case invalidMessage
}

final class BitgetCandleWebSocketClient: CandleStreamService {
    private let url: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        url: URL = URL(string: "wss://ws.bitget.com/v2/ws/public")!,
        session: URLSession = .shared,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.url = url
        self.session = session
        self.encoder = encoder
        self.decoder = decoder
    }

    func streamCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) -> AsyncStream<Candle> {
        AsyncStream { continuation in
            let streamTask = Task {
                var reconnectDelay: UInt64 = 1_000_000_000

                while !Task.isCancelled {
                    let webSocket = session.webSocketTask(with: url)
                    webSocket.resume()

                    let pingTask = makePingTask(for: webSocket)

                    do {
                        try await subscribe(webSocket, symbol: symbol, timeframe: timeframe)
                        reconnectDelay = 1_000_000_000

                        while !Task.isCancelled {
                            let message = try await webSocket.receive()
                            let candles = try decodeCandles(
                                message,
                                symbol: symbol,
                                timeframe: timeframe
                            )
                            for candle in candles {
                                continuation.yield(candle)
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

    private func subscribe(
        _ webSocket: URLSessionWebSocketTask,
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) async throws {
        let request = BitgetWebSocketSubscriptionRequest(
            op: "subscribe",
            args: [
                BitgetWebSocketChannelArg(
                    instType: ProductType.usdtFutures.rawValue,
                    channel: timeframe.bitgetWebSocketChannel,
                    instId: symbol.rawValue
                )
            ]
        )
        let data = try encoder.encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BitgetWebSocketError.invalidMessage
        }
        try await webSocket.send(.string(text))
    }

    private func decodeCandles(
        _ message: URLSessionWebSocketTask.Message,
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) throws -> [Candle] {
        let data: Data
        switch message {
        case .string(let text):
            guard text != "pong" else { return [] }
            data = Data(text.utf8)
        case .data(let payload):
            data = payload
        @unknown default:
            throw BitgetWebSocketError.invalidMessage
        }

        let payload = try decoder.decode(BitgetWebSocketCandlePayload.self, from: data)
        if payload.event == "error" {
            throw BitgetWebSocketError.server(
                code: payload.code ?? "unknown",
                message: payload.msg ?? "Bitget WebSocket error"
            )
        }

        guard payload.arg?.instId == symbol.rawValue,
              payload.arg?.channel == timeframe.bitgetWebSocketChannel,
              let rows = payload.data else {
            return []
        }

        return rows.compactMap { row in
            BitgetCandleRow(values: row).domain(
                symbol: symbol,
                timeframe: timeframe,
                isClosed: false
            )
        }
    }
}

private struct BitgetWebSocketSubscriptionRequest: Encodable {
    let op: String
    let args: [BitgetWebSocketChannelArg]
}

struct BitgetWebSocketChannelArg: Codable, Equatable {
    let instType: String
    let channel: String
    let instId: String
}

struct BitgetWebSocketCandlePayload: Decodable, Equatable {
    let event: String?
    let action: String?
    let arg: BitgetWebSocketChannelArg?
    let data: [[String]]?
    let code: String?
    let msg: String?
    let ts: Int?
}

private extension CandleTimeframe {
    var bitgetWebSocketChannel: String {
        "candle\(bitgetGranularity)"
    }
}
