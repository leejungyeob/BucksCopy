import Foundation

enum ExchangeProtectionOrderKind: String, Codable, Equatable {
    case takeProfit
    case stopLoss
}

enum ExchangeProtectionExecution: String, Codable, Equatable {
    case limit
    case market
}

struct ExchangeProtectionOrder: Codable, Equatable, Identifiable {
    let id: String
    let kind: ExchangeProtectionOrderKind
    let symbol: FuturesSymbol
    let holdSide: PositionSide
    let triggerPrice: Decimal
    let executePrice: Decimal?
    let size: Decimal
    let marginCoin: String
    let clientOid: String

    var execution: ExchangeProtectionExecution {
        executePrice == nil ? .market : .limit
    }
}

struct ExchangeProtectionPlan: Codable, Equatable, Identifiable {
    let id: UUID
    let symbol: FuturesSymbol
    let holdSide: PositionSide
    let size: Decimal
    let partialTakeProfit: Decimal
    let takeProfit: Decimal
    let profitLockStopLoss: Decimal
    let stopLoss: Decimal
    let marginCoin: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        signal: StrategySignal,
        size: Decimal,
        marginCoin: String = "USDT",
        createdAt: Date = Date()
    ) {
        self.id = id
        symbol = signal.symbol
        holdSide = PositionSide(openedBy: signal.side)
        self.size = size
        partialTakeProfit = signal.partialTakeProfit
        takeProfit = signal.takeProfit
        profitLockStopLoss = signal.profitLockStopLossAfterPartialTakeProfit
        stopLoss = signal.stopLoss
        self.marginCoin = marginCoin
        self.createdAt = createdAt
    }

    var orders: [ExchangeProtectionOrder] {
        let partialSize = size * SplitTakeProfitPlan.partialTakeProfitRatio
        let finalSize = size - partialSize
        return [
            ExchangeProtectionOrder(
                id: "\(id.uuidString)-tp1",
                kind: .takeProfit,
                symbol: symbol,
                holdSide: holdSide,
                triggerPrice: partialTakeProfit,
                executePrice: partialTakeProfit,
                size: partialSize,
                marginCoin: marginCoin,
                clientOid: "\(id.uuidString)-tp1"
            ),
            ExchangeProtectionOrder(
                id: "\(id.uuidString)-tp2",
                kind: .takeProfit,
                symbol: symbol,
                holdSide: holdSide,
                triggerPrice: takeProfit,
                executePrice: takeProfit,
                size: finalSize,
                marginCoin: marginCoin,
                clientOid: "\(id.uuidString)-tp2"
            ),
            ExchangeProtectionOrder(
                id: "\(id.uuidString)-sl",
                kind: .stopLoss,
                symbol: symbol,
                holdSide: holdSide,
                triggerPrice: stopLoss,
                executePrice: nil,
                size: size,
                marginCoin: marginCoin,
                clientOid: "\(id.uuidString)-sl"
            )
        ]
    }

    func validate() throws {
        guard holdSide != .unknown else {
            throw TradingDomainError.invalidProtectionPlan("position side is unknown")
        }
        guard size > 0 else {
            throw TradingDomainError.invalidProtectionPlan("position size must be greater than zero")
        }
        guard partialTakeProfit > 0, takeProfit > 0, profitLockStopLoss > 0, stopLoss > 0 else {
            throw TradingDomainError.invalidProtectionPlan("take-profit and stop-loss prices must be positive")
        }
    }
}

struct ExchangeProtectionReceipt: Codable, Equatable {
    let orderID: String
    let clientOid: String
    let kind: ExchangeProtectionOrderKind
    let attempts: Int
}

struct ExchangeProtectionRetryPolicy: Codable, Equatable {
    static let minimumRetryCount = 5

    let retryCount: Int
    let retryDelayNanoseconds: UInt64

    init(
        retryCount: Int = Self.minimumRetryCount,
        retryDelayNanoseconds: UInt64 = 250_000_000
    ) {
        self.retryCount = max(retryCount, Self.minimumRetryCount)
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }
}

protocol ExchangeProtectionOrderPlacing {
    func placeProtectionOrder(_ order: ExchangeProtectionOrder) async throws -> ExchangeProtectionReceipt
}

struct ExchangeProtectionInstaller: PositionProtectionInstalling {
    private let orderPlacer: ExchangeProtectionOrderPlacing
    private let retryPolicy: ExchangeProtectionRetryPolicy

    init(
        orderPlacer: ExchangeProtectionOrderPlacing,
        retryPolicy: ExchangeProtectionRetryPolicy = ExchangeProtectionRetryPolicy()
    ) {
        self.orderPlacer = orderPlacer
        self.retryPolicy = retryPolicy
    }

    func installProtection(_ plan: ExchangeProtectionPlan) async throws -> [ExchangeProtectionReceipt] {
        try plan.validate()
        var receipts: [ExchangeProtectionReceipt] = []
        receipts.reserveCapacity(plan.orders.count)

        for order in plan.orders {
            receipts.append(try await placeWithRetry(order))
        }

        return receipts
    }

    private func placeWithRetry(_ order: ExchangeProtectionOrder) async throws -> ExchangeProtectionReceipt {
        let maximumAttempts = retryPolicy.retryCount + 1
        var attempts = 0

        while attempts < maximumAttempts {
            attempts += 1
            do {
                let receipt = try await orderPlacer.placeProtectionOrder(order)
                return ExchangeProtectionReceipt(
                    orderID: receipt.orderID,
                    clientOid: receipt.clientOid,
                    kind: receipt.kind,
                    attempts: attempts
                )
            } catch {
                guard attempts < maximumAttempts else {
                    throw TradingDomainError.protectionOrderRetryExhausted(
                        kind: order.kind,
                        attempts: attempts
                    )
                }
                if retryPolicy.retryDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: retryPolicy.retryDelayNanoseconds)
                }
            }
        }

        throw TradingDomainError.protectionOrderRetryExhausted(kind: order.kind, attempts: attempts)
    }
}

extension PositionSide {
    init(openedBy side: TradeSide) {
        switch side {
        case .buy:
            self = .long
        case .sell:
            self = .short
        }
    }
}
