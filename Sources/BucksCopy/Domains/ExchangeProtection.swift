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
    let positionMode: PositionMode
    let tradeSide: TradeSide
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
    let positionMode: PositionMode
    let tradeSide: TradeSide
    let size: Decimal
    let partialTakeProfit: Decimal
    let takeProfit: Decimal
    let profitLockStopLoss: Decimal
    let stopLoss: Decimal
    let marginCoin: String
    let sizeMultiplier: Decimal?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        signal: StrategySignal,
        size: Decimal,
        marginCoin: String = "USDT",
        positionMode: PositionMode = .hedge,
        contractSpec: ContractSpec? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        symbol = signal.symbol
        holdSide = PositionSide(openedBy: signal.side)
        self.positionMode = positionMode
        tradeSide = signal.side
        self.size = Self.floor(size, step: contractSpec?.sizeMultiplier)
        partialTakeProfit = Self.roundPrice(signal.partialTakeProfit, pricePlace: contractSpec?.pricePlace)
        takeProfit = Self.roundPrice(signal.takeProfit, pricePlace: contractSpec?.pricePlace)
        profitLockStopLoss = Self.roundPrice(signal.profitLockStopLossAfterPartialTakeProfit, pricePlace: contractSpec?.pricePlace)
        stopLoss = Self.roundPrice(signal.stopLoss, pricePlace: contractSpec?.pricePlace)
        self.marginCoin = marginCoin
        sizeMultiplier = contractSpec?.sizeMultiplier
        self.createdAt = createdAt
    }

    var orders: [ExchangeProtectionOrder] {
        let partialSize = Self.floor(size * SplitTakeProfitPlan.partialTakeProfitRatio, step: sizeMultiplier)
        let finalSize = size - partialSize
        return [
            ExchangeProtectionOrder(
                id: "\(id.uuidString)-tp1",
                kind: .takeProfit,
                symbol: symbol,
                holdSide: holdSide,
                positionMode: positionMode,
                tradeSide: tradeSide,
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
                positionMode: positionMode,
                tradeSide: tradeSide,
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
                positionMode: positionMode,
                tradeSide: tradeSide,
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
        guard orders.allSatisfy({ $0.size > 0 }) else {
            throw TradingDomainError.invalidProtectionPlan("split protection size must be greater than zero")
        }
        guard partialTakeProfit > 0, takeProfit > 0, profitLockStopLoss > 0, stopLoss > 0 else {
            throw TradingDomainError.invalidProtectionPlan("take-profit and stop-loss prices must be positive")
        }
    }

    private static func roundPrice(_ value: Decimal, pricePlace: Int?) -> Decimal {
        guard let pricePlace else { return value }
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, max(pricePlace, 0), .plain)
        return output
    }

    private static func floor(_ value: Decimal, step: Decimal?) -> Decimal {
        guard let step, step > 0 else { return value }
        let valueNumber = NSDecimalNumber(decimal: value)
        let stepNumber = NSDecimalNumber(decimal: step)
        let units = valueNumber.dividing(by: stepNumber).doubleValue.rounded(.down)
        return Decimal(units) * step
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
        var lastError: Error?

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
                lastError = error
                guard attempts < maximumAttempts else {
                    throw TradingDomainError.protectionOrderRetryExhausted(
                        kind: order.kind,
                        attempts: attempts,
                        cause: Self.sanitizedCause(from: error)
                    )
                }
                if retryPolicy.retryDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: retryPolicy.retryDelayNanoseconds)
                }
            }
        }

        throw TradingDomainError.protectionOrderRetryExhausted(
            kind: order.kind,
            attempts: attempts,
            cause: Self.sanitizedCause(from: lastError)
        )
    }

    private static func sanitizedCause(from error: Error?) -> String? {
        guard let error else { return nil }
        if let publicError = error as? PublicTradingErrorDescribing {
            return publicError.tradingLogDescription
        }
        if let domainError = error as? TradingDomainError {
            return domainError.description
        }
        return String(describing: type(of: error))
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
