import Foundation

final class SQLiteTradeEventLogStore: TradeEventLogStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) throws {
        self.database = database
        try createTableIfNeeded()
    }

    convenience init(path: String) throws {
        try self.init(database: SQLiteDatabase(path: path))
    }

    func append(_ log: TradeEventLog) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO trade_event_logs
            (id, timestamp, category, severity, symbol, message)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind(log.id.uuidString, at: 1)
        try statement.bind(log.timestamp.timeIntervalSince1970, at: 2)
        try statement.bind(log.category.rawValue, at: 3)
        try statement.bind(log.severity.rawValue, at: 4)
        try statement.bind(log.symbol?.rawValue, at: 5)
        try statement.bind(log.message, at: 6)
        _ = try statement.step()
    }

    func loadRecent(limit: Int) throws -> [TradeEventLog] {
        let statement = try database.prepare(
            """
            SELECT id, timestamp, category, severity, symbol, message
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
                message: message
            ))
        }

        return logs.sorted { $0.timestamp < $1.timestamp }
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
                message TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_trade_event_logs_timestamp
            ON trade_event_logs(timestamp DESC);
            """
        )
    }
}
