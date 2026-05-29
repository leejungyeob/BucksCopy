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
    private let candleRepository: SQLiteCandleRepository
    private let logStore: SQLiteTradeEventLogStore
    private let stateStore: PaperRunnerStateStore
    private let candleClient: BitgetPaperCandleClient
    private let evaluator: TradingSignalEvaluator
    private let strategyRegistry = StrategyRegistry()
    private let clock: Clock
    private let databasePath: String

    init(config: PaperRunnerConfig, clock: Clock = SystemClock()) throws {
        self.config = config
        self.clock = clock
        try FileManager.default.createDirectory(
            at: config.dataDirectory,
            withIntermediateDirectories: true
        )
        databasePath = config.dataDirectory
            .appendingPathComponent("bucks-copy.sqlite")
            .path
        let database = try SQLiteDatabase(path: databasePath)
        candleRepository = try SQLiteCandleRepository(database: database)
        logStore = try SQLiteTradeEventLogStore(database: database)
        stateStore = try PaperRunnerStateStore(database: database)
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
            databasePath: databasePath
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
                    TradeLogDetail(label: "DB", value: status.databasePath)
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

struct PaperRunnerStatus: Equatable {
    let updatedAt: Date
    let mode: String
    let symbols: [String]
    let latestClosedCandleOpenTime: Date?
    let savedCandles: Int
    let evaluations: Int
    let signals: Int
    let failures: [String]
    let databasePath: String

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

final class PaperRunnerStateStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) throws {
        self.database = database
        try createTablesIfNeeded()
    }

    func hasEvaluated(_ key: PaperRunnerEvaluationKey) throws -> Bool {
        let statement = try database.prepare(
            """
            SELECT evaluation_key
            FROM paper_runner_evaluations
            WHERE evaluation_key = ?
            LIMIT 1;
            """
        )
        try statement.bind(key.rawValue, at: 1)
        return try statement.step()
    }

    func markEvaluated(
        _ key: PaperRunnerEvaluationKey,
        producedSignal: Bool,
        evaluatedAt: Date
    ) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO paper_runner_evaluations
            (evaluation_key, symbol, timeframe, strategy_id, candle_open_time, produced_signal, evaluated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind(key.rawValue, at: 1)
        try statement.bind(key.symbol.rawValue, at: 2)
        try statement.bind(key.timeframe.rawValue, at: 3)
        try statement.bind(key.strategyID, at: 4)
        try statement.bind(key.candleOpenTime.timeIntervalSince1970, at: 5)
        try statement.bind(producedSignal ? 1 : 0, at: 6)
        try statement.bind(evaluatedAt.timeIntervalSince1970, at: 7)
        _ = try statement.step()
    }

    func saveStatus(_ status: PaperRunnerStatus) throws {
        let failureText = status.failures.joined(separator: "\n")
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO paper_runner_status
            (id, updated_at, mode, symbols, latest_closed_candle_open_time, saved_candles, evaluations, signals, failures, database_path)
            VALUES ('current', ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind(status.updatedAt.timeIntervalSince1970, at: 1)
        try statement.bind(status.mode, at: 2)
        try statement.bind(status.symbols.joined(separator: ","), at: 3)
        try statement.bind(status.latestClosedCandleOpenTime?.timeIntervalSince1970 ?? 0, at: 4)
        try statement.bind(status.savedCandles, at: 5)
        try statement.bind(status.evaluations, at: 6)
        try statement.bind(status.signals, at: 7)
        try statement.bind(failureText, at: 8)
        try statement.bind(status.databasePath, at: 9)
        _ = try statement.step()
    }

    func shouldLogHeartbeat(now: Date, minimumInterval: TimeInterval = 15 * 60) throws -> Bool {
        let statement = try database.prepare(
            """
            SELECT logged_at
            FROM paper_runner_heartbeat
            WHERE id = 'last'
            LIMIT 1;
            """
        )
        guard try statement.step() else {
            return true
        }
        let latest = Date(timeIntervalSince1970: statement.double(at: 0))
        return now.timeIntervalSince(latest) >= minimumInterval
    }

    func saveHeartbeatLogTime(_ loggedAt: Date) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO paper_runner_heartbeat
            (id, logged_at)
            VALUES ('last', ?);
            """
        )
        try statement.bind(loggedAt.timeIntervalSince1970, at: 1)
        _ = try statement.step()
    }

    private func createTablesIfNeeded() throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS paper_runner_evaluations (
                evaluation_key TEXT PRIMARY KEY NOT NULL,
                symbol TEXT NOT NULL,
                timeframe TEXT NOT NULL,
                strategy_id TEXT NOT NULL,
                candle_open_time REAL NOT NULL,
                produced_signal INTEGER NOT NULL,
                evaluated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_paper_runner_evaluations_symbol_time
            ON paper_runner_evaluations(symbol, timeframe, candle_open_time DESC);

            CREATE TABLE IF NOT EXISTS paper_runner_status (
                id TEXT PRIMARY KEY NOT NULL,
                updated_at REAL NOT NULL,
                mode TEXT NOT NULL,
                symbols TEXT NOT NULL,
                latest_closed_candle_open_time REAL NOT NULL,
                saved_candles INTEGER NOT NULL,
                evaluations INTEGER NOT NULL,
                signals INTEGER NOT NULL,
                failures TEXT NOT NULL,
                database_path TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS paper_runner_heartbeat (
                id TEXT PRIMARY KEY NOT NULL,
                logged_at REAL NOT NULL
            );
            """
        )
    }
}
