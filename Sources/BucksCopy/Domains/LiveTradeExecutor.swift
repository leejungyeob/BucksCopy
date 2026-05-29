import Foundation

struct LiveTradeExecutionResult: Equatable {
    let didSubmitOrder: Bool
    let closedPositions: [LiveClosePositionReceipt]
    let entryReceipt: LiveOrderReceipt?
    let protectionReceipts: [ExchangeProtectionReceipt]
}

private enum LivePositionCloseLogContext {
    case replacement
    case holdingPeriod(PositionHoldingPeriodExit)
}

final class LiveTradeExecutor {
    private let orderPlacer: LiveOrderPlacing
    private let leverageSetter: LiveLeverageSetting
    private let protectionInstaller: PositionProtectionInstalling
    private let positionRepository: PositionRepository?
    private let logStore: TradeEventLogStore
    private let clock: Clock
    private let positionVerificationAttempts: Int
    private let positionVerificationDelayNanoseconds: UInt64

    init(
        orderPlacer: LiveOrderPlacing,
        leverageSetter: LiveLeverageSetting,
        protectionInstaller: PositionProtectionInstalling,
        positionRepository: PositionRepository? = nil,
        logStore: TradeEventLogStore,
        clock: Clock = SystemClock(),
        positionVerificationAttempts: Int = 3,
        positionVerificationDelayNanoseconds: UInt64 = 350_000_000
    ) {
        self.orderPlacer = orderPlacer
        self.leverageSetter = leverageSetter
        self.protectionInstaller = protectionInstaller
        self.positionRepository = positionRepository
        self.logStore = logStore
        self.clock = clock
        self.positionVerificationAttempts = max(positionVerificationAttempts, 1)
        self.positionVerificationDelayNanoseconds = positionVerificationDelayNanoseconds
    }

    func execute(
        decision: PortfolioSignalDecision,
        accountEquity: Decimal?,
        accountAvailable: Decimal? = nil,
        contractSpecs: [ContractSpec],
        signalEvaluator: TradingSignalEvaluator
    ) async throws -> LiveTradeExecutionResult {
        switch decision {
        case .noAction:
            return LiveTradeExecutionResult(
                didSubmitOrder: false,
                closedPositions: [],
                entryReceipt: nil,
                protectionReceipts: []
            )
        case .enter(let candidate, let reason):
            let entry = try await enter(
                candidate,
                accountEquity: accountEquity,
                accountAvailable: accountAvailable,
                contractSpecs: contractSpecs,
                portfolioDecisionReason: reason
            )
            try signalEvaluator.recordLiveOrder(
                candidate,
                receipt: entry.receipt,
                protectionReceipts: entry.protectionReceipts,
                portfolioDecisionReason: reason
            )
            return LiveTradeExecutionResult(
                didSubmitOrder: true,
                closedPositions: [],
                entryReceipt: entry.receipt,
                protectionReceipts: entry.protectionReceipts
            )
        case .replace(let existing, let candidate, let reason):
            let closeReceipt = try await close(position: existing.position, context: .replacement)
            let replacementReason = "Live replacement policy. \(reason)"
            let entry = try await enter(
                candidate,
                accountEquity: accountEquity,
                accountAvailable: accountAvailable,
                contractSpecs: contractSpecs,
                portfolioDecisionReason: replacementReason
            )
            try signalEvaluator.recordLiveOrder(
                candidate,
                receipt: entry.receipt,
                protectionReceipts: entry.protectionReceipts,
                portfolioDecisionReason: replacementReason
            )
            return LiveTradeExecutionResult(
                didSubmitOrder: true,
                closedPositions: [closeReceipt],
                entryReceipt: entry.receipt,
                protectionReceipts: entry.protectionReceipts
            )
        case .holdExisting(_, let bestCandidate, let reason):
            try signalEvaluator.recordPortfolioDecision(
                symbol: bestCandidate.signal.symbol,
                message: "Live signal held: \(reason)"
            )
            return LiveTradeExecutionResult(
                didSubmitOrder: false,
                closedPositions: [],
                entryReceipt: nil,
                protectionReceipts: []
            )
        }
    }

    func closeHoldingPeriodExits(_ exits: [PositionHoldingPeriodExit]) async throws -> LiveTradeExecutionResult {
        var receipts: [LiveClosePositionReceipt] = []
        for exit in exits {
            receipts.append(try await close(position: exit.position, context: .holdingPeriod(exit)))
        }
        return LiveTradeExecutionResult(
            didSubmitOrder: receipts.isEmpty == false,
            closedPositions: receipts,
            entryReceipt: nil,
            protectionReceipts: []
        )
    }

    private func enter(
        _ candidate: TradeCandidate,
        accountEquity: Decimal?,
        accountAvailable: Decimal?,
        contractSpecs: [ContractSpec],
        portfolioDecisionReason: String
    ) async throws -> (receipt: LiveOrderReceipt, protectionReceipts: [ExchangeProtectionReceipt]) {
        guard let accountEquity, accountEquity > 0 else {
            throw TradingDomainError.missingAccountEquity
        }
        guard let contractSpec = contractSpecs.first(where: { $0.symbol == candidate.signal.symbol }) else {
            throw TradingDomainError.missingContractSpec(candidate.signal.symbol)
        }

        let size = try LiveOrderSizing.size(
            for: candidate,
            accountEquity: accountEquity,
            accountAvailable: accountAvailable,
            contractSpec: contractSpec
        )
        let orderID = UUID()
        let request = LiveOrderRequest(
            id: orderID,
            symbol: candidate.signal.symbol,
            side: candidate.signal.side,
            purpose: .open,
            size: size,
            leverage: candidate.leverage,
            marginMode: "isolated",
            reduceOnly: false
        )

        try await leverageSetter.setLeverage(
            symbol: candidate.signal.symbol,
            leverage: candidate.leverage,
            marginCoin: request.marginCoin
        )
        let receipt = try await orderPlacer.placeMarketOrder(request)
        guard receipt.status == .filled,
              let filledSize = receipt.filledSize,
              filledSize > 0 else {
            throw TradingDomainError.liveOrderFillNotConfirmed(receipt.clientOid)
        }

        let holdSide = PositionSide(openedBy: candidate.signal.side)
        let confirmedPosition = try await confirmOpenPositionIfPossible(
            candidate: candidate,
            holdSide: holdSide,
            clientOid: receipt.clientOid,
            portfolioDecisionReason: portfolioDecisionReason
        )
        let protectionSize = confirmedPosition?.total ?? filledSize
        let positionMode = confirmedPosition?.positionMode ?? .hedge

        do {
            let protectionPlan = ExchangeProtectionPlan(
                signal: candidate.signal,
                size: protectionSize,
                marginCoin: request.marginCoin,
                positionMode: positionMode,
                contractSpec: contractSpec,
                createdAt: clock.now
            )
            let receipts = try await protectionInstaller.installProtection(protectionPlan)
            return (receipt, receipts)
        } catch {
            await failClosedAfterUnprotectedEntry(
                candidate: candidate,
                holdSide: holdSide,
                originalError: error,
                portfolioDecisionReason: portfolioDecisionReason
            )
            throw error
        }
    }

    private func close(position: PortfolioOpenPositionAssessment) async throws -> LiveClosePositionReceipt {
        try await close(position: position.position, context: .replacement)
    }

    private func confirmOpenPositionIfPossible(
        candidate: TradeCandidate,
        holdSide: PositionSide,
        clientOid: String,
        portfolioDecisionReason: String
    ) async throws -> PositionSnapshot? {
        guard positionRepository != nil else { return nil }
        let signal = candidate.signal
        for attempt in 0..<positionVerificationAttempts {
            if attempt > 0, positionVerificationDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: positionVerificationDelayNanoseconds)
            }
            if let position = try await matchingOpenPosition(symbol: signal.symbol, holdSide: holdSide) {
                return position
            }
        }

        try logStore.append(TradeEventLog(
            timestamp: clock.now,
            category: .risk,
            severity: .warning,
            symbol: signal.symbol,
            message: "Live entry fill receipt did not match an open position. Protection orders and fail-closed close were skipped. Order \(TradeLogRedaction.identifier(clientOid)).",
            metadata: TradeLogMetadata(
                title: "\(signal.symbol.rawValue) \(candidate.timeframe.rawValue) 포지션 미확인",
                subtitle: "\(signal.strategyID) 시그널 체결 응답은 받았지만 현재 포지션이 확인되지 않아 보호주문과 시장가 청산을 모두 중단했습니다.",
                tags: [
                    TradeLogTag(label: "LIVE", tone: .success),
                    TradeLogTag(label: candidate.timeframe.rawValue, tone: .accent),
                    TradeLogTag(label: signal.strategyID, tone: .neutral),
                    TradeLogTag(label: "확인 필요", tone: .warning),
                    TradeLogTag(label: "청산 생략", tone: .warning)
                ],
                details: [
                    TradeLogDetail(label: "매매전략", value: signal.strategyID, tone: .accent),
                    TradeLogDetail(label: "시간봉", value: candidate.timeframe.rawValue, tone: .accent),
                    TradeLogDetail(label: "심볼", value: signal.symbol.rawValue),
                    TradeLogDetail(label: "예상 방향", value: holdSide.rawValue),
                    TradeLogDetail(label: "주문 ID", value: TradeLogRedaction.identifier(clientOid)),
                    TradeLogDetail(label: "진입가", value: DecimalText.string(signal.entryPrice)),
                    TradeLogDetail(label: "손절가", value: DecimalText.string(signal.stopLoss), tone: .danger),
                    TradeLogDetail(label: "익절가", value: DecimalText.string(signal.takeProfit), tone: .success),
                    TradeLogDetail(label: "시그널 근거", value: signal.reason),
                    TradeLogDetail(label: "선정 로직", value: portfolioDecisionReason),
                    TradeLogDetail(label: "처리", value: "보호주문/시장가 청산 중단", tone: .warning)
                ]
            )
        ))
        throw TradingDomainError.liveEntryPositionNotConfirmed(clientOid)
    }

    private func matchingOpenPosition(
        symbol: FuturesSymbol,
        holdSide: PositionSide
    ) async throws -> PositionSnapshot? {
        guard let positionRepository else { return nil }
        return try await positionRepository.fetchPositions().first { position in
            guard position.symbol == symbol, position.total > 0 else { return false }
            if position.side == holdSide {
                return true
            }
            return position.positionMode == .oneWay
        }
    }

    private func close(
        position: PositionSnapshot,
        context: LivePositionCloseLogContext
    ) async throws -> LiveClosePositionReceipt {
        guard position.total > 0,
              position.side != .unknown || position.positionMode == .oneWay else {
            return LiveClosePositionReceipt(symbol: position.symbol, orderIDs: [])
        }
        let holdSide: PositionSide? = position.positionMode == .oneWay ? nil : position.side
        let sideText = position.side == .unknown ? position.positionMode.rawValue : position.side.rawValue
        let receipt = try await orderPlacer.closePosition(symbol: position.symbol, holdSide: holdSide)
        let orderText = receipt.orderIDs
            .map(TradeLogRedaction.identifier)
            .joined(separator: ",")
        let logTitle: String
        let logSubtitle: String
        let closeReasonDetail: TradeLogDetail
        var tags: [TradeLogTag] = [
            TradeLogTag(label: "LIVE", tone: .success),
            TradeLogTag(label: "청산", tone: .warning),
            TradeLogTag(label: sideText.uppercased(), tone: .neutral),
            TradeLogTag(
                label: closeOutcomeText(for: position.unrealizedProfitLoss),
                tone: closeOutcomeTone(for: position.unrealizedProfitLoss)
            )
        ]
        var extraDetails: [TradeLogDetail] = []
        switch context {
        case .replacement:
            logTitle = "\(position.symbol.rawValue) 기존 포지션 정리"
            logSubtitle = "새 신호 우선순위가 더 높아 기존 \(sideText) 포지션 시장가 정리를 요청했습니다."
            closeReasonDetail = TradeLogDetail(label: "청산 근거", value: "새 신호 우선순위가 기존 포지션보다 높음", tone: .warning)
        case .holdingPeriod(let exit):
            logTitle = "\(position.symbol.rawValue) \(exit.timeframe.rawValue) 보유기간 종료"
            logSubtitle = "\(exit.strategyID) 포지션이 최대 보유 기간 \(exit.maximumHoldingCandles)봉을 지나 시장가 정리를 요청했습니다."
            closeReasonDetail = TradeLogDetail(label: "청산 근거", value: exit.reason, tone: .warning)
            tags.append(contentsOf: [
                TradeLogTag(label: exit.timeframe.rawValue, tone: .accent),
                TradeLogTag(label: exit.strategyID, tone: .neutral),
                TradeLogTag(label: "시간 종료", tone: .warning)
            ])
            extraDetails.append(contentsOf: [
                TradeLogDetail(label: "매매전략", value: exit.strategyID, tone: .accent),
                TradeLogDetail(label: "시간봉", value: exit.timeframe.rawValue, tone: .accent),
                TradeLogDetail(label: "진입시각", value: "\(Int(exit.enteredAt.timeIntervalSince1970))"),
                TradeLogDetail(label: "최대 보유", value: "\(exit.maximumHoldingCandles)봉"),
                TradeLogDetail(label: "경과 봉수", value: "\(exit.elapsedCandles)봉", tone: .warning)
            ])
        }
        let details = [
            TradeLogDetail(label: "심볼", value: position.symbol.rawValue),
            TradeLogDetail(label: "포지션 방향", value: sideText),
            TradeLogDetail(label: "수량", value: DecimalText.string(position.total)),
            TradeLogDetail(label: "마크가", value: DecimalText.string(position.markPrice)),
            TradeLogDetail(
                label: "청산 직전 PnL",
                value: DecimalText.string(position.unrealizedProfitLoss),
                tone: closeOutcomeTone(for: position.unrealizedProfitLoss)
            ),
            TradeLogDetail(
                label: "청산 판정",
                value: closeOutcomeText(for: position.unrealizedProfitLoss),
                tone: closeOutcomeTone(for: position.unrealizedProfitLoss)
            ),
            closeReasonDetail,
            TradeLogDetail(label: "주문 ID", value: orderText.isEmpty ? "-" : orderText)
        ] + extraDetails
        try logStore.append(TradeEventLog(
            timestamp: clock.now,
            category: .liveOrder,
            symbol: position.symbol,
            message: "Live position close submitted for \(position.symbol.rawValue) \(sideText). Reason: \(closeReasonDetail.value). Orders: \(orderText)",
            metadata: TradeLogMetadata(
                title: logTitle,
                subtitle: logSubtitle,
                tags: tags,
                details: details
            )
        ))
        return receipt
    }

    private func failClosedAfterUnprotectedEntry(
        candidate: TradeCandidate,
        holdSide: PositionSide,
        originalError: Error,
        portfolioDecisionReason: String
    ) async {
        let signal = candidate.signal
        let symbol = signal.symbol
        try? logStore.append(TradeEventLog(
            timestamp: clock.now,
            category: .risk,
            severity: .error,
            symbol: symbol,
            message: "Protection order installation failed after live entry. Verifying open position before fail-closed close. Cause: \(sanitizedErrorDescription(originalError)).",
            metadata: TradeLogMetadata(
                title: "\(symbol.rawValue) \(candidate.timeframe.rawValue) 보호주문 실패",
                subtitle: "\(signal.strategyID) 시그널 진입 후 TP/SL 보호주문이 완전히 등록되지 않아 현재 포지션을 확인한 뒤 필요할 때만 청산합니다.",
                tags: [
                    TradeLogTag(label: "RISK", tone: .danger),
                    TradeLogTag(label: candidate.timeframe.rawValue, tone: .accent),
                    TradeLogTag(label: signal.strategyID, tone: .neutral),
                    TradeLogTag(label: "보호주문 실패", tone: .danger),
                    TradeLogTag(label: "Fail-Closed", tone: .warning)
                ],
                details: [
                    TradeLogDetail(label: "매매전략", value: signal.strategyID, tone: .accent),
                    TradeLogDetail(label: "시간봉", value: candidate.timeframe.rawValue, tone: .accent),
                    TradeLogDetail(label: "심볼", value: symbol.rawValue),
                    TradeLogDetail(label: "포지션 방향", value: holdSide.rawValue),
                    TradeLogDetail(label: "진입가", value: DecimalText.string(signal.entryPrice)),
                    TradeLogDetail(label: "손절가", value: DecimalText.string(signal.stopLoss), tone: .danger),
                    TradeLogDetail(label: "TP1", value: "\(DecimalText.string(signal.partialTakeProfit)) / 50%", tone: .success),
                    TradeLogDetail(label: "TP2", value: "\(DecimalText.string(signal.takeProfit)) / 50%", tone: .success),
                    TradeLogDetail(label: "시그널 근거", value: signal.reason),
                    TradeLogDetail(label: "선정 로직", value: portfolioDecisionReason),
                    TradeLogDetail(label: "실패 원인", value: sanitizedErrorDescription(originalError), tone: .danger),
                    TradeLogDetail(label: "처리", value: "포지션 확인 후 청산 판단", tone: .warning)
                ]
            )
        ))
        let closeHoldSide: PositionSide?
        if positionRepository == nil {
            closeHoldSide = holdSide
        } else {
            do {
                guard let position = try await matchingOpenPosition(symbol: symbol, holdSide: holdSide) else {
                    try? logStore.append(TradeEventLog(
                        timestamp: clock.now,
                        category: .risk,
                        severity: .warning,
                        symbol: symbol,
                        message: "Fail-closed close skipped because no open \(symbol.rawValue) \(holdSide.rawValue) position was found.",
                        metadata: TradeLogMetadata(
                            title: "\(symbol.rawValue) fail-closed 청산 생략",
                            subtitle: "\(signal.strategyID) 시그널 포지션 청산 직전 조회에서 닫을 포지션이 없어 시장가 청산 주문을 보내지 않았습니다.",
                            tags: [
                                TradeLogTag(label: "LIVE", tone: .success),
                                TradeLogTag(label: candidate.timeframe.rawValue, tone: .accent),
                                TradeLogTag(label: signal.strategyID, tone: .neutral),
                                TradeLogTag(label: "청산 생략", tone: .warning),
                                TradeLogTag(label: "포지션 없음", tone: .warning)
                            ],
                            details: [
                                TradeLogDetail(label: "매매전략", value: signal.strategyID, tone: .accent),
                                TradeLogDetail(label: "시간봉", value: candidate.timeframe.rawValue, tone: .accent),
                                TradeLogDetail(label: "심볼", value: symbol.rawValue),
                                TradeLogDetail(label: "예상 방향", value: holdSide.rawValue),
                                TradeLogDetail(label: "시그널 근거", value: signal.reason),
                                TradeLogDetail(label: "선정 로직", value: portfolioDecisionReason),
                                TradeLogDetail(label: "처리", value: "시장가 청산 미전송", tone: .warning)
                            ]
                        )
                    ))
                    return
                }
                closeHoldSide = position.positionMode == .oneWay ? nil : holdSide
            } catch {
                try? logStore.append(TradeEventLog(
                    timestamp: clock.now,
                    category: .risk,
                    severity: .error,
                    symbol: symbol,
                    message: "Fail-closed position verification failed; market close was not submitted. Cause: \(sanitizedErrorDescription(error)).",
                    metadata: TradeLogMetadata(
                        title: "\(symbol.rawValue) fail-closed 확인 실패",
                        subtitle: "\(signal.strategyID) 시그널 포지션 청산 전 조회가 실패해 시장가 청산을 보내지 않았습니다. 수동 확인이 필요합니다.",
                        tags: [
                            TradeLogTag(label: "RISK", tone: .danger),
                            TradeLogTag(label: candidate.timeframe.rawValue, tone: .accent),
                            TradeLogTag(label: signal.strategyID, tone: .neutral),
                            TradeLogTag(label: "수동 확인", tone: .danger)
                        ],
                        details: [
                            TradeLogDetail(label: "매매전략", value: signal.strategyID, tone: .accent),
                            TradeLogDetail(label: "시간봉", value: candidate.timeframe.rawValue, tone: .accent),
                            TradeLogDetail(label: "심볼", value: symbol.rawValue),
                            TradeLogDetail(label: "예상 방향", value: holdSide.rawValue),
                            TradeLogDetail(label: "시그널 근거", value: signal.reason),
                            TradeLogDetail(label: "선정 로직", value: portfolioDecisionReason),
                            TradeLogDetail(label: "실패 원인", value: sanitizedErrorDescription(error), tone: .danger)
                        ]
                    )
                ))
                return
            }
        }
        do {
            let receipt = try await orderPlacer.closePosition(symbol: symbol, holdSide: closeHoldSide)
            let orderText = receipt.orderIDs
                .map(TradeLogRedaction.identifier)
                .joined(separator: ",")
            try? logStore.append(TradeEventLog(
                timestamp: clock.now,
                category: .liveOrder,
                severity: .warning,
                symbol: symbol,
                message: "Fail-closed live position close submitted for \(symbol.rawValue) \(holdSide.rawValue). Orders: \(orderText)",
                metadata: TradeLogMetadata(
                    title: "\(symbol.rawValue) fail-closed 청산 요청",
                    subtitle: "\(signal.strategyID) 시그널 보호주문 실패 후 unprotected 포지션을 닫기 위해 시장가 청산을 요청했습니다.",
                    tags: [
                        TradeLogTag(label: "LIVE", tone: .success),
                        TradeLogTag(label: candidate.timeframe.rawValue, tone: .accent),
                        TradeLogTag(label: signal.strategyID, tone: .neutral),
                        TradeLogTag(label: "Fail-Closed", tone: .warning),
                        TradeLogTag(label: holdSide.rawValue.uppercased(), tone: .neutral)
                    ],
                    details: [
                        TradeLogDetail(label: "매매전략", value: signal.strategyID, tone: .accent),
                        TradeLogDetail(label: "시간봉", value: candidate.timeframe.rawValue, tone: .accent),
                        TradeLogDetail(label: "심볼", value: symbol.rawValue),
                        TradeLogDetail(label: "포지션 방향", value: holdSide.rawValue),
                        TradeLogDetail(label: "시그널 근거", value: signal.reason),
                        TradeLogDetail(label: "선정 로직", value: portfolioDecisionReason),
                        TradeLogDetail(label: "주문 ID", value: orderText.isEmpty ? "-" : orderText)
                    ]
                )
            ))
        } catch {
            try? logStore.append(TradeEventLog(
                timestamp: clock.now,
                category: .risk,
                severity: .error,
                symbol: symbol,
                message: "Fail-closed market close failed after unprotected live entry. Cause: \(sanitizedErrorDescription(error)).",
                metadata: TradeLogMetadata(
                    title: "\(symbol.rawValue) fail-closed 청산 실패",
                    subtitle: "\(signal.strategyID) 시그널의 보호되지 않은 실포지션 청산 요청이 실패했습니다. 즉시 수동 확인이 필요합니다.",
                    tags: [
                        TradeLogTag(label: "RISK", tone: .danger),
                        TradeLogTag(label: candidate.timeframe.rawValue, tone: .accent),
                        TradeLogTag(label: signal.strategyID, tone: .neutral),
                        TradeLogTag(label: "수동 확인", tone: .danger)
                    ],
                    details: [
                        TradeLogDetail(label: "매매전략", value: signal.strategyID, tone: .accent),
                        TradeLogDetail(label: "시간봉", value: candidate.timeframe.rawValue, tone: .accent),
                        TradeLogDetail(label: "심볼", value: symbol.rawValue),
                        TradeLogDetail(label: "포지션 방향", value: holdSide.rawValue),
                        TradeLogDetail(label: "시그널 근거", value: signal.reason),
                        TradeLogDetail(label: "선정 로직", value: portfolioDecisionReason),
                        TradeLogDetail(label: "실패 원인", value: sanitizedErrorDescription(error), tone: .danger)
                    ]
                )
            ))
        }
    }

    private func sanitizedErrorDescription(_ error: Error) -> String {
        if let publicError = error as? PublicTradingErrorDescribing {
            return publicError.tradingLogDescription
        }
        if let domainError = error as? TradingDomainError {
            return domainError.description
        }
        return String(describing: type(of: error))
    }

    private func closeOutcomeText(for profitLoss: Decimal) -> String {
        if profitLoss > 0 { return "승" }
        if profitLoss < 0 { return "패" }
        return "본전"
    }

    private func closeOutcomeTone(for profitLoss: Decimal) -> TradeLogTone {
        if profitLoss > 0 { return .success }
        if profitLoss < 0 { return .danger }
        return .neutral
    }
}

final class UnavailableLiveOrderClient: LiveOrderPlacing, LiveLeverageSetting, ExchangeProtectionOrderPlacing {
    func setLeverage(symbol: FuturesSymbol, leverage: Int, marginCoin: String) async throws {
        throw TradingDomainError.liveTradingDisabled
    }

    func placeMarketOrder(_ request: LiveOrderRequest) async throws -> LiveOrderReceipt {
        throw TradingDomainError.liveTradingDisabled
    }

    func closePosition(
        symbol: FuturesSymbol,
        holdSide: PositionSide?
    ) async throws -> LiveClosePositionReceipt {
        throw TradingDomainError.liveTradingDisabled
    }

    func placeProtectionOrder(_ order: ExchangeProtectionOrder) async throws -> ExchangeProtectionReceipt {
        throw TradingDomainError.liveTradingDisabled
    }
}

enum LiveOrderSizing {
    static func size(
        for candidate: TradeCandidate,
        accountEquity: Decimal,
        accountAvailable: Decimal? = nil,
        contractSpec: ContractSpec
    ) throws -> Decimal {
        let plannedMargin = accountEquity * candidate.riskDecision.positionMarginRatio
        let availableMargin = accountAvailable.flatMap { $0 > 0 ? $0 : nil } ?? accountEquity
        let usableMargin = min(plannedMargin, availableMargin * Decimal(string: "0.95")!)
        guard usableMargin > 0 else {
            throw TradingDomainError.liveOrderSizeTooSmall(candidate.signal.symbol)
        }
        let notional = usableMargin * Decimal(candidate.leverage)
        let rawSize = notional / candidate.signal.entryPrice
        let roundedSize = floor(rawSize, step: contractSpec.sizeMultiplier)

        guard roundedSize >= contractSpec.minTradeNum,
              roundedSize * candidate.signal.entryPrice >= contractSpec.minTradeUSDT else {
            throw TradingDomainError.liveOrderSizeTooSmall(candidate.signal.symbol)
        }

        return roundedSize
    }

    private static func floor(_ value: Decimal, step: Decimal) -> Decimal {
        guard step > 0 else { return value }
        let valueNumber = NSDecimalNumber(decimal: value)
        let stepNumber = NSDecimalNumber(decimal: step)
        let units = valueNumber.dividing(by: stepNumber).doubleValue.rounded(.down)
        return Decimal(units) * step
    }
}
