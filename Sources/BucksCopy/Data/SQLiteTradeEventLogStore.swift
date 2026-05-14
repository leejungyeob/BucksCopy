import Foundation

final class SQLiteTradeEventLogStore: TradeEventLogStore {
    private let database: SQLiteDatabase
    private let queue = DispatchQueue(label: "BucksCopy.SQLiteTradeEventLogStore")

    init(database: SQLiteDatabase) throws {
        self.database = database
        try createTableIfNeeded()
    }

    convenience init(path: String) throws {
        try self.init(database: SQLiteDatabase(path: path))
    }

    func append(_ log: TradeEventLog) throws {
        try queue.sync {
            let statement = try database.prepare(
                """
                INSERT OR REPLACE INTO trade_event_logs
                (id, timestamp, category, severity, symbol, message, metadata_json)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """
            )
            try statement.bind(log.id.uuidString, at: 1)
            try statement.bind(log.timestamp.timeIntervalSince1970, at: 2)
            try statement.bind(log.category.rawValue, at: 3)
            try statement.bind(log.severity.rawValue, at: 4)
            try statement.bind(log.symbol?.rawValue, at: 5)
            try statement.bind(log.message, at: 6)
            try statement.bind(Self.metadataJSON(log.metadata), at: 7)
            _ = try statement.step()
        }
    }

    func loadRecent(limit: Int) throws -> [TradeEventLog] {
        try queue.sync {
            let statement = try database.prepare(
                """
                SELECT id, timestamp, category, severity, symbol, message, metadata_json
                FROM trade_event_logs
                ORDER BY timestamp DESC
                LIMIT ?;
                """
            )
            try statement.bind(limit, at: 1)

            var logs: [TradeEventLog] = []
            while try statement.step() {
                guard
                    let idText = statement.string(at: 0),
                    let id = UUID(uuidString: idText),
                    let categoryText = statement.string(at: 2),
                    let category = TradeEventCategory(rawValue: categoryText),
                    let severityText = statement.string(at: 3),
                    let severity = TradeEventSeverity(rawValue: severityText),
                    let message = statement.string(at: 5)
                else {
                    continue
                }

                let symbolText = statement.string(at: 4)
                logs.append(TradeEventLog(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: statement.double(at: 1)),
                    category: category,
                    severity: severity,
                    symbol: symbolText.map(FuturesSymbol.init),
                    message: message,
                    metadata: Self.metadata(from: statement.string(at: 6))
                ))
            }

            return logs.sorted { $0.timestamp < $1.timestamp }
        }
    }

    private func createTableIfNeeded() throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS trade_event_logs (
                id TEXT PRIMARY KEY NOT NULL,
                timestamp REAL NOT NULL,
                category TEXT NOT NULL,
                severity TEXT NOT NULL,
                symbol TEXT,
                message TEXT NOT NULL,
                metadata_json TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_trade_event_logs_timestamp
            ON trade_event_logs(timestamp DESC);
            """
        )
        if try !hasColumn("metadata_json", in: "trade_event_logs") {
            try database.execute("ALTER TABLE trade_event_logs ADD COLUMN metadata_json TEXT;")
        }
    }

    private func hasColumn(_ column: String, in table: String) throws -> Bool {
        let statement = try database.prepare("PRAGMA table_info(\(table));")
        while try statement.step() {
            if statement.string(at: 1) == column {
                return true
            }
        }
        return false
    }

    private static func metadataJSON(_ metadata: TradeLogMetadata?) -> String? {
        guard let metadata,
              let data = try? JSONEncoder().encode(metadata) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func metadata(from json: String?) -> TradeLogMetadata? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(TradeLogMetadata.self, from: data)
    }
}
