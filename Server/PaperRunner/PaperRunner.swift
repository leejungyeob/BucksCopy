import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct PaperRunnerConfig: Equatable {
    let dataDirectory: URL
    let symbols: [FuturesSymbol]
    let candleLimit: Int
    let pollIntervalSeconds: UInt64
    let runOnce: Bool
    let baseURL: URL

    var pollIntervalNanoseconds: UInt64 {
        pollIntervalSeconds * 1_000_000_000
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> PaperRunnerConfig {
        let dataDirectory = URL(
            fileURLWithPath: environment["BUCKS_COPY_DATA_DIR"] ?? "/var/lib/bucks-copy",
            isDirectory: true
        )
        let symbols = (environment["BUCKS_COPY_SYMBOLS"] ?? "BTCUSDT,ETHUSDT")
            .split(separator: ",")
            .map { FuturesSymbol(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.rawValue.isEmpty }

        guard !symbols.isEmpty else {
            throw PaperRunnerError.invalidConfiguration("BUCKS_COPY_SYMBOLS must include at least one symbol.")
        }

        let candleLimit = max(Int(environment["BUCKS_COPY_CANDLE_LIMIT"] ?? "") ?? 500, 50)
        let pollIntervalSeconds = max(UInt64(environment["BUCKS_COPY_POLL_SECONDS"] ?? "") ?? 30, 5)
        let runOnceText = environment["BUCKS_COPY_RUN_ONCE"]?.lowercased() ?? "false"
        let runOnce = ["1", "true", "yes", "y"].contains(runOnceText)
        let baseURL = URL(string: environment["BUCKS_COPY_BITGET_BASE_URL"] ?? "https://api.bitget.com")

        guard let baseURL else {
            throw PaperRunnerError.invalidConfiguration("BUCKS_COPY_BITGET_BASE_URL is invalid.")
        }

        return PaperRunnerConfig(
            dataDirectory: dataDirectory,
            symbols: symbols,
            candleLimit: candleLimit,
            pollIntervalSeconds: pollIntervalSeconds,
            runOnce: runOnce,
            baseURL: baseURL
        )
    }
}

enum PaperRunnerError: Error, Equatable {
    case invalidConfiguration(String)
    case invalidURL
    case httpStatus(Int)
    case bitgetAPI(code: String, message: String)
    case emptyResponse
}

enum PaperRunnerErrorText {
    static func publicDescription(_ error: Error) -> String {
        switch error {
        case let error as PaperRunnerError:
            switch error {
            case .invalidConfiguration(let message):
                return message
            case .invalidURL:
                return "Bitget public request URL invalid"
            case .httpStatus(let status):
                return "Bitget public HTTP \(status)"
            case .bitgetAPI(let code, let message):
                return "Bitget public API \(code): \(message)"
            case .emptyResponse:
                return "Bitget public API returned empty response"
            }
        case let urlError as URLError:
            return "Network request failed: \(urlError.localizedDescription)"
        case let domainError as TradingDomainError:
            return domainError.description
        case let publicError as PublicTradingErrorDescribing:
            return publicError.tradingLogDescription
        default:
            return String(describing: type(of: error))
        }
    }
}

final class PaperRunner {
    private let config: PaperRunnerConfig
    private let candleRepository: FileCandleRepository
    private let logStore: FileTradeEventLogStore
    private let stateStore: PaperRunnerFileStateStore
    private let candleClient: BitgetPaperCandleClient
    private let evaluator: TradingSignalEvaluator
    private let strategyRegistry = StrategyRegistry()
    private let clock: Clock
    private let storagePath: String

    init(config: PaperRunnerConfig, clock: Clock = SystemClock()) throws {
        self.config = config
        self.clock = clock
        try FileManager.default.createDirectory(
            at: config.dataDirectory,
            withIntermediateDirectories: true
        )
        storagePath = config.dataDirectory.path
        candleRepository = FileCandleRepository(directory: config.dataDirectory)
        logStore = FileTradeEventLogStore(
            fileURL: config.dataDirectory.appendingPathComponent("trade-event-logs.jsonl")
        )
        stateStore = try PaperRunnerFileStateStore(directory: config.dataDirectory)
        candleClient = BitgetPaperCandleClient(baseURL: config.baseURL)
        evaluator = TradingSignalEvaluator(
            strategyRegistry: strategyRegistry,
            logStore: logStore,
            clock: clock
        )
    }

    func runOnce() async throws {
        let startedAt = clock.now
        var savedCandles = 0
        var evaluations = 0
        var signals = 0
        var failures: [String] = []
        var latestClosedOpenTime: Date?

        for symbol in config.symbols {
            do {
                let remoteCandles = try await candleClient.fetchCandles(
                    symbol: symbol,
                    timeframe: .fifteenMinutes,
                    limit: config.candleLimit
                )
                try candleRepository.upsertCandles(remoteCandles)
                savedCandles += remoteCandles.count

                let storedCandles = try candleRepository.loadCandles(
                    symbol: symbol,
                    timeframe: .fifteenMinutes,
                    limit: config.candleLimit
                )
                .filter { $0.isClosed }
                .sorted { $0.openTime < $1.openTime }

                guard let latestClosed = storedCandles.last else {
                    failures.append("\(symbol.rawValue): no closed 15m candle available")
                    continue
                }
                latestClosedOpenTime = maxDate(latestClosedOpenTime, latestClosed.openTime)

                let definitions = strategyRegistry.definitions(
                    recommendedFor: .fifteenMinutes,
                    symbol: symbol
                )
                for definition in definitions {
                    let evaluationKey = PaperRunnerEvaluationKey(
                        symbol: symbol,
                        timeframe: .fifteenMinutes,
                        strategyID: definition.id,
                        candleOpenTime: latestClosed.openTime
                    )
                    guard try !stateStore.hasEvaluated(evaluationKey) else {
                        continue
                    }

                    do {
                        var strategyConfig = definition.defaultConfig
                        strategyConfig.leverage = min(strategyConfig.leverage, 10)
                        let candidate = try evaluator.makeCandidate(
                            symbol: symbol,
                            watchlist: config.symbols,
                            timeframe: .fifteenMinutes,
                            candleOpenTime: latestClosed.openTime,
                            candles: storedCandles,
                            config: strategyConfig,
                            includesLiveFormingCandle: false
                        )
                        evaluations += 1
                        if let candidate {
                            signals += 1
                            try recordPaperSignal(candidate)
                        }
                        try stateStore.markEvaluated(
                            evaluationKey,
                            producedSignal: candidate != nil,
                            evaluatedAt: clock.now
                        )
                    } catch {
                        evaluations += 1
                        failures.append(
                            "\(symbol.rawValue) \(definition.id): \(PaperRunnerErrorText.publicDescription(error))"
                        )
                    }
                }
            } catch {
                failures.append("\(symbol.rawValue): \(PaperRunnerErrorText.publicDescription(error))")
            }
        }

        let status = PaperRunnerStatus(
            updatedAt: clock.now,
            mode: "paper",
            symbols: config.symbols.map(\.rawValue),
            latestClosedCandleOpenTime: latestClosedOpenTime,
            savedCandles: savedCandles,
            evaluations: evaluations,
            signals: signals,
            failures: failures,
            storagePath: storagePath
        )
        try stateStore.saveStatus(status)
        try logHeartbeatIfNeeded(status, startedAt: startedAt)
        print(status.consoleSummary)
    }

    private func recordPaperSignal(_ candidate: TradeCandidate) throws {
        let signal = candidate.signal
        try logStore.append(TradeEventLog(
            timestamp: clock.now,
            category: .signal,
            symbol: signal.symbol,
            message: "Paper signal generated by \(signal.strategyID) on \(candidate.timeframe.rawValue). Side \(signal.side.rawValue), entry \(DecimalText.string(signal.entryPrice)), stop \(DecimalText.string(signal.stopLoss)), TP1 \(DecimalText.string(signal.partialTakeProfit)), TP2 \(DecimalText.string(signal.takeProfit)). Reason: \(signal.reason). No live order was submitted.",
            metadata: TradeLogMetadata(
                title: "\(signal.symbol.rawValue) \(candidate.timeframe.rawValue) paper signal",
                subtitle: "\(signal.strategyID) 전략이 closed 15m candle 기준 paper 후보를 만들었습니다. 실주문은 전송하지 않았습니다.",
                tags: [
                    TradeLogTag(label: "PAPER", tone: .accent),
                    TradeLogTag(label: candidate.timeframe.rawValue, tone: .accent),
                    TradeLogTag(label: signal.side.rawValue.uppercased(), tone: .neutral),
                    TradeLogTag(label: signal.strategyID, tone: .neutral)
                ],
                details: [
                    TradeLogDetail(label: "매매전략", value: signal.strategyID, tone: .accent),
                    TradeLogDetail(label: "시간봉", value: candidate.timeframe.rawValue, tone: .accent),
                    TradeLogDetail(label: "심볼", value: signal.symbol.rawValue),
                    TradeLogDetail(label: "방향", value: signal.side.rawValue),
                    TradeLogDetail(label: "진입가", value: DecimalText.string(signal.entryPrice), tone: .accent),
                    TradeLogDetail(label: "손절가", value: DecimalText.string(signal.stopLoss), tone: .danger),
                    TradeLogDetail(label: "TP1", value: DecimalText.string(signal.partialTakeProfit), tone: .success),
                    TradeLogDetail(label: "TP2", value: DecimalText.string(signal.takeProfit), tone: .success),
                    TradeLogDetail(label: "손익비", value: "\(signal.plannedRewardRiskRatio?.riskText ?? "-"):1", tone: .success),
                    TradeLogDetail(label: "레버리지", value: "\(candidate.leverage)x", tone: .accent),
                    TradeLogDetail(label: "실행 모드", value: "paper-only"),
                    TradeLogDetail(label: "시그널 근거", value: signal.reason)
                ]
            )
        ))
    }

    private func logHeartbeatIfNeeded(_ status: PaperRunnerStatus, startedAt: Date) throws {
        guard try stateStore.shouldLogHeartbeat(now: status.updatedAt) else {
            return
        }

        let elapsed = max(status.updatedAt.timeIntervalSince(startedAt), 0)
        try logStore.append(TradeEventLog(
            timestamp: status.updatedAt,
            category: .automation,
            symbol: nil,
            message: "Paper runner heartbeat. Symbols \(status.symbols.joined(separator: ",")), saved candles \(status.savedCandles), evaluations \(status.evaluations), signals \(status.signals), failures \(status.failures.count), elapsed \(String(format: "%.2f", elapsed))s. No live orders enabled.",
            metadata: TradeLogMetadata(
                title: "Paper runner heartbeat",
                subtitle: "서버 runner가 15m closed candle 기준 paper 평가를 수행했습니다.",
                tags: [
                    TradeLogTag(label: "PAPER", tone: .accent),
                    TradeLogTag(label: "15m", tone: .accent),
                    TradeLogTag(label: status.failures.isEmpty ? "OK" : "CHECK", tone: status.failures.isEmpty ? .success : .warning)
                ],
                details: [
                    TradeLogDetail(label: "심볼", value: status.symbols.joined(separator: ",")),
                    TradeLogDetail(label: "저장 candle", value: "\(status.savedCandles)"),
                    TradeLogDetail(label: "평가 수", value: "\(status.evaluations)"),
                    TradeLogDetail(label: "paper signal", value: "\(status.signals)"),
                    TradeLogDetail(label: "실패 수", value: "\(status.failures.count)", tone: status.failures.isEmpty ? .neutral : .warning),
                    TradeLogDetail(label: "저장소", value: status.storagePath)
                ]
            )
        ))
        try stateStore.saveHeartbeatLogTime(status.updatedAt)
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }
}

final class FileCandleRepository: CandleRepository {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL) {
        self.directory = directory
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) throws -> [Candle] {
        let candles = try loadAllCandles(symbol: symbol, timeframe: timeframe)
        return Array(candles.suffix(max(limit, 0)))
    }

    func loadAllCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) throws -> [Candle] {
        let fileURL = candlesURL(symbol: symbol, timeframe: timeframe)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([Candle].self, from: data)
            .sorted { $0.openTime < $1.openTime }
    }

    func loadOldestCandleOpenTime(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) throws -> Date? {
        try loadAllCandles(symbol: symbol, timeframe: timeframe).first?.openTime
    }

    func upsertCandles(_ candles: [Candle]) throws {
        let grouped = Dictionary(grouping: candles) { candle in
            "\(candle.symbol.rawValue)-\(candle.timeframe.rawValue)"
        }

        for (_, candlesForRoute) in grouped {
            guard let sample = candlesForRoute.first else { continue }
            let existing = try loadAllCandles(
                symbol: sample.symbol,
                timeframe: sample.timeframe
            )
            var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for candle in candlesForRoute {
                merged[candle.id] = candle
            }

            let sorted = merged.values.sorted { $0.openTime < $1.openTime }
            let data = try encoder.encode(sorted)
            try data.write(
                to: candlesURL(symbol: sample.symbol, timeframe: sample.timeframe),
                options: [.atomic]
            )
        }
    }

    private func candlesURL(symbol: FuturesSymbol, timeframe: CandleTimeframe) -> URL {
        directory.appendingPathComponent("candles-\(symbol.rawValue)-\(timeframe.rawValue).json")
    }
}

final class FileTradeEventLogStore: TradeEventLogStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.sortedKeys]
    }

    func append(_ log: TradeEventLog) throws {
        let data = try encoder.encode(log) + Data("\n".utf8)
        try append(data, to: fileURL)
    }

    func loadRecent(limit: Int) throws -> [TradeEventLog] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let logs = text
            .split(separator: "\n")
            .compactMap { line -> TradeEventLog? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(TradeEventLog.self, from: data)
            }
            .sorted { $0.timestamp < $1.timestamp }
        return Array(logs.suffix(max(limit, 0)))
    }

    private func append(_ data: Data, to fileURL: URL) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

final class BitgetPaperCandleClient {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetchCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) async throws -> [Candle] {
        guard let url = Self.url(
            baseURL: baseURL,
            path: "/api/v2/mix/market/candles",
            queryItems: [
                URLQueryItem(name: "granularity", value: timeframe.bitgetGranularity),
                URLQueryItem(name: "limit", value: String(min(max(limit, 1), 1000))),
                URLQueryItem(name: "productType", value: ProductType.usdtFutures.rawValue),
                URLQueryItem(name: "symbol", value: symbol.rawValue)
            ]
        ) else {
            throw PaperRunnerError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("en-US", forHTTPHeaderField: "locale")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw PaperRunnerError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw PaperRunnerError.emptyResponse
        }

        let decoded = try JSONDecoder().decode(BitgetPaperResponse<[BitgetPaperCandleRow]>.self, from: data)
        guard decoded.code == "00000" else {
            throw PaperRunnerError.bitgetAPI(code: decoded.code, message: decoded.msg)
        }

        let receivedAt = Date()
        return decoded.data.compactMap { row in
            row.domain(symbol: symbol, timeframe: timeframe, receivedAt: receivedAt)
        }
        .sorted { $0.openTime < $1.openTime }
    }

    private static func url(baseURL: URL, path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems.sorted { $0.name < $1.name }
        return components?.url
    }
}

private struct BitgetPaperResponse<DataPayload: Decodable>: Decodable {
    let code: String
    let msg: String
    let data: DataPayload
}

private struct BitgetPaperCandleRow: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [String] = []
        while !container.isAtEnd {
            values.append(try container.decode(String.self))
        }
        self.values = values
    }

    func domain(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        receivedAt: Date
    ) -> Candle? {
        guard values.count >= 6,
              let milliseconds = Double(values[0]) else {
            return nil
        }

        let openTime = Date(timeIntervalSince1970: milliseconds / 1000)
        return Candle(
            productType: .usdtFutures,
            symbol: symbol,
            timeframe: timeframe,
            openTime: openTime,
            open: DecimalText.parse(values[1]),
            high: DecimalText.parse(values[2]),
            low: DecimalText.parse(values[3]),
            close: DecimalText.parse(values[4]),
            volume: DecimalText.parse(values[5]),
            isClosed: openTime.addingTimeInterval(timeframe.duration) <= receivedAt
        )
    }
}

struct PaperRunnerEvaluationKey: Equatable {
    let symbol: FuturesSymbol
    let timeframe: CandleTimeframe
    let strategyID: String
    let candleOpenTime: Date

    var rawValue: String {
        "\(symbol.rawValue):\(timeframe.rawValue):\(strategyID):\(Int(candleOpenTime.timeIntervalSince1970))"
    }
}

struct PaperRunnerStatus: Codable, Equatable {
    let updatedAt: Date
    let mode: String
    let symbols: [String]
    let latestClosedCandleOpenTime: Date?
    let savedCandles: Int
    let evaluations: Int
    let signals: Int
    let failures: [String]
    let storagePath: String

    var consoleSummary: String {
        let latestText = latestClosedCandleOpenTime.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        let statusText = failures.isEmpty ? "ok" : "check"
        return [
            "[\(ISO8601DateFormatter().string(from: updatedAt))]",
            "paper-runner=\(statusText)",
            "symbols=\(symbols.joined(separator: ","))",
            "latestClosed=\(latestText)",
            "saved=\(savedCandles)",
            "evaluations=\(evaluations)",
            "signals=\(signals)",
            "failures=\(failures.count)"
        ].joined(separator: " ")
    }
}

final class PaperRunnerFileStateStore {
    private let directory: URL
    private let statusURL: URL
    private let evaluationsURL: URL
    private let heartbeatURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var evaluatedKeys: Set<String>

    init(directory: URL) throws {
        self.directory = directory
        statusURL = directory.appendingPathComponent("paper-runner-status.json")
        evaluationsURL = directory.appendingPathComponent("paper-runner-evaluations.jsonl")
        heartbeatURL = directory.appendingPathComponent("paper-runner-heartbeat.json")
        encoder.outputFormatting = [.sortedKeys]
        evaluatedKeys = try Self.loadEvaluatedKeys(from: evaluationsURL)
    }

    func hasEvaluated(_ key: PaperRunnerEvaluationKey) throws -> Bool {
        evaluatedKeys.contains(key.rawValue)
    }

    func markEvaluated(
        _ key: PaperRunnerEvaluationKey,
        producedSignal: Bool,
        evaluatedAt: Date
    ) throws {
        guard evaluatedKeys.insert(key.rawValue).inserted else {
            return
        }
        let record = PaperRunnerEvaluationRecord(
            evaluationKey: key.rawValue,
            symbol: key.symbol.rawValue,
            timeframe: key.timeframe.rawValue,
            strategyID: key.strategyID,
            candleOpenTime: key.candleOpenTime,
            producedSignal: producedSignal,
            evaluatedAt: evaluatedAt
        )
        let data = try encoder.encode(record) + Data("\n".utf8)
        try append(data, to: evaluationsURL)
    }

    func saveStatus(_ status: PaperRunnerStatus) throws {
        let data = try encoder.encode(status)
        try data.write(to: statusURL, options: [.atomic])
    }

    func shouldLogHeartbeat(now: Date, minimumInterval: TimeInterval = 15 * 60) throws -> Bool {
        guard FileManager.default.fileExists(atPath: heartbeatURL.path) else {
            return true
        }
        let data = try Data(contentsOf: heartbeatURL)
        let latest = try decoder.decode(PaperRunnerHeartbeat.self, from: data).loggedAt
        return now.timeIntervalSince(latest) >= minimumInterval
    }

    func saveHeartbeatLogTime(_ loggedAt: Date) throws {
        let data = try encoder.encode(PaperRunnerHeartbeat(loggedAt: loggedAt))
        try data.write(to: heartbeatURL, options: [.atomic])
    }

    private static func loadEvaluatedKeys(from fileURL: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        return Set(text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(PaperRunnerEvaluationRecord.self, from: data) else {
                return nil
            }
            return record.evaluationKey
        })
    }

    private func append(_ data: Data, to fileURL: URL) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

private struct PaperRunnerEvaluationRecord: Codable {
    let evaluationKey: String
    let symbol: String
    let timeframe: String
    let strategyID: String
    let candleOpenTime: Date
    let producedSignal: Bool
    let evaluatedAt: Date
}

private struct PaperRunnerHeartbeat: Codable {
    let loggedAt: Date
}
