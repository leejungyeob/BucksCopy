import Foundation

enum SignalEvidenceGroup: String, Codable, CaseIterable, Equatable, Hashable {
    case trend
    case structure
    case pattern
    case momentum
    case volume
    case volatility
    case riskContext
}

struct SignalEvidence: Codable, Equatable, Identifiable {
    let id: String
    let group: SignalEvidenceGroup
    let score: Decimal
    let reason: String
}

struct SignalConfirmationScore: Codable, Equatable {
    let totalScore: Decimal
    let rawScore: Decimal
    let requiredScore: Decimal
    let evidences: [SignalEvidence]

    var isConfirmed: Bool {
        totalScore >= requiredScore
    }

    var summaryText: String {
        "\(totalScore.riskText)/\(requiredScore.riskText)"
    }
}

enum SignalConfirmationMode: String, Codable, CaseIterable, Equatable, Identifiable {
    case off
    case observe
    case gate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "OFF"
        case .observe:
            return "Observe"
        case .gate:
            return "Gate"
        }
    }
}

struct SignalConfirmationConfig: Codable, Equatable {
    var mode: SignalConfirmationMode
    var requiredScore: Decimal
    var groupScoreCaps: [SignalEvidenceGroup: Decimal]

    var isEnabled: Bool {
        get { mode != .off }
        set { mode = newValue ? .gate : .off }
    }

    static let optimizedDefault = SignalConfirmationConfig(
        mode: .off,
        requiredScore: 22,
        groupScoreCaps: [
            .trend: 20,
            .structure: 18,
            .pattern: 14,
            .momentum: 10,
            .volume: 8,
            .volatility: 8,
            .riskContext: 10
        ]
    )

    static let observeDefault = SignalConfirmationConfig(
        mode: .observe,
        requiredScore: optimizedDefault.requiredScore,
        groupScoreCaps: optimizedDefault.groupScoreCaps
    )

    static let disabled = SignalConfirmationConfig(
        mode: .off,
        requiredScore: 0,
        groupScoreCaps: optimizedDefault.groupScoreCaps
    )

    init(
        mode: SignalConfirmationMode,
        requiredScore: Decimal,
        groupScoreCaps: [SignalEvidenceGroup: Decimal]
    ) {
        self.mode = mode
        self.requiredScore = requiredScore
        self.groupScoreCaps = groupScoreCaps
    }

    init(
        isEnabled: Bool,
        requiredScore: Decimal,
        groupScoreCaps: [SignalEvidenceGroup: Decimal]
    ) {
        self.init(
            mode: isEnabled ? .gate : .off,
            requiredScore: requiredScore,
            groupScoreCaps: groupScoreCaps
        )
    }
}

enum SignalConfirmationScoreBucket: String, Codable, CaseIterable, Equatable, Identifiable {
    case belowZero
    case zeroToTen
    case tenToTwenty
    case twentyToThirty
    case thirtyToForty
    case fortyPlus

    var id: String { rawValue }

    var label: String {
        switch self {
        case .belowZero:
            return "< 0"
        case .zeroToTen:
            return "0-10"
        case .tenToTwenty:
            return "10-20"
        case .twentyToThirty:
            return "20-30"
        case .thirtyToForty:
            return "30-40"
        case .fortyPlus:
            return "40+"
        }
    }

    static func bucket(for score: Decimal) -> SignalConfirmationScoreBucket {
        if score < 0 { return .belowZero }
        if score < 10 { return .zeroToTen }
        if score < 20 { return .tenToTwenty }
        if score < 30 { return .twentyToThirty }
        if score < 40 { return .thirtyToForty }
        return .fortyPlus
    }
}

protocol SignalConfirmationRule {
    var id: String { get }
    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence?
}

struct SignalConfirmationDecision: Equatable {
    let isAllowed: Bool
    let score: SignalConfirmationScore?
    let reason: String
    let maximumRiskPerTradeMultiplier: Decimal

    init(
        isAllowed: Bool,
        score: SignalConfirmationScore?,
        reason: String,
        maximumRiskPerTradeMultiplier: Decimal = 1
    ) {
        self.isAllowed = isAllowed
        self.score = score
        self.reason = reason
        self.maximumRiskPerTradeMultiplier = maximumRiskPerTradeMultiplier
    }

    var blockSummaryReason: String {
        reason
    }
}

struct SignalConfirmationProfile: Equatable {
    struct RiskTier: Equatable {
        let minimumSoftMatches: Int
        let maximumRiskMultiplier: Decimal
    }

    let name: String
    let hardGateEvidenceIDs: Set<String>
    let softGateEvidenceIDs: Set<String>
    let minimumSoftMatchesToAllow: Int
    let riskTiers: [RiskTier]
    let inactiveReason: String?

    var isActive: Bool {
        inactiveReason == nil
    }

    var evidenceIDs: Set<String> {
        hardGateEvidenceIDs.union(softGateEvidenceIDs)
    }

    func maximumRiskMultiplier(softMatches: Int) -> Decimal {
        guard isActive else { return 1 }
        return riskTiers
            .filter { softMatches >= $0.minimumSoftMatches }
            .map(\.maximumRiskMultiplier)
            .max() ?? 1
    }

    static func researchDefault(
        strategyID: String,
        timeframe: CandleTimeframe
    ) -> SignalConfirmationProfile? {
        switch (strategyID, timeframe) {
        case (MovingAverageAlignmentStrategy.identifier, .fifteenMinutes):
            return SignalConfirmationProfile(
                name: "15m 이평선 RSI/지지저항/피보나치",
                hardGateEvidenceIDs: [],
                softGateEvidenceIDs: [
                    SignalConfirmationEvidenceID.rsiMomentum,
                    SignalConfirmationEvidenceID.supportResistance,
                    SignalConfirmationEvidenceID.fibonacciPullback
                ],
                minimumSoftMatchesToAllow: 1,
                riskTiers: [
                    RiskTier(minimumSoftMatches: 1, maximumRiskMultiplier: Decimal(string: "0.65")!),
                    RiskTier(minimumSoftMatches: 2, maximumRiskMultiplier: Decimal(string: "0.85")!),
                    RiskTier(minimumSoftMatches: 3, maximumRiskMultiplier: 1)
                ],
                inactiveReason: nil
            )
        case (MovingAverageAlignmentStrategy.identifier, .oneHour):
            return SignalConfirmationProfile(
                name: "1H 이평선 MA 추세 정렬",
                hardGateEvidenceIDs: [SignalConfirmationEvidenceID.trendAlignment],
                softGateEvidenceIDs: [],
                minimumSoftMatchesToAllow: 0,
                riskTiers: [],
                inactiveReason: nil
            )
        case (BlockedCandleShortStrategy.identifier, .fourHours):
            return SignalConfirmationProfile(
                name: "4H 막힘봉 지지저항/신호봉",
                hardGateEvidenceIDs: [],
                softGateEvidenceIDs: [
                    SignalConfirmationEvidenceID.supportResistance,
                    SignalConfirmationEvidenceID.candleQuality
                ],
                minimumSoftMatchesToAllow: 1,
                riskTiers: [
                    RiskTier(minimumSoftMatches: 1, maximumRiskMultiplier: Decimal(string: "0.75")!),
                    RiskTier(minimumSoftMatches: 2, maximumRiskMultiplier: 1)
                ],
                inactiveReason: nil
            )
        case (MovingAverageAlignmentStrategy.identifier, .fourHours):
            return SignalConfirmationProfile(
                name: "4H 이평선 MA 추세 정렬",
                hardGateEvidenceIDs: [SignalConfirmationEvidenceID.trendAlignment],
                softGateEvidenceIDs: [],
                minimumSoftMatchesToAllow: 0,
                riskTiers: [],
                inactiveReason: nil
            )
        case (VWMATouchTrendStrategy.identifier, .twelveHours):
            return SignalConfirmationProfile(
                name: "12H VWMA 보조지표 OFF",
                hardGateEvidenceIDs: [],
                softGateEvidenceIDs: [],
                minimumSoftMatchesToAllow: 0,
                riskTiers: [],
                inactiveReason: "12H VWMA는 동조/비동조 성과 차이가 작아 전용 보조지표를 적용하지 않음"
            )
        case (VWMATouchTrendStrategy.identifier, .oneDay):
            return SignalConfirmationProfile(
                name: "1D VWMA 더블탑/바텀",
                hardGateEvidenceIDs: [SignalConfirmationEvidenceID.doubleTopBottom],
                softGateEvidenceIDs: [
                    SignalConfirmationEvidenceID.fibonacciPullback,
                    SignalConfirmationEvidenceID.candleQuality
                ],
                minimumSoftMatchesToAllow: 0,
                riskTiers: [
                    RiskTier(minimumSoftMatches: 0, maximumRiskMultiplier: Decimal(string: "0.80")!),
                    RiskTier(minimumSoftMatches: 1, maximumRiskMultiplier: Decimal(string: "0.90")!),
                    RiskTier(minimumSoftMatches: 2, maximumRiskMultiplier: 1)
                ],
                inactiveReason: nil
            )
        default:
            return nil
        }
    }
}

enum SignalConfirmationEvidenceID {
    static let trendAlignment = "trend-alignment"
    static let supportResistance = "support-resistance"
    static let rsiMomentum = "rsi-momentum"
    static let volumeExpansion = "volume-expansion"
    static let atrRegime = "atr-regime"
    static let fibonacciPullback = "fibonacci-pullback"
    static let doubleTopBottom = "double-top-bottom"
    static let candleQuality = "candle-quality"

    static func displayName(_ id: String) -> String {
        switch id {
        case trendAlignment:
            return "MA 추세 정렬"
        case supportResistance:
            return "지지/저항 ATR 거리"
        case rsiMomentum:
            return "RSI 모멘텀"
        case volumeExpansion:
            return "거래량 확장"
        case atrRegime:
            return "ATR 변동성 구간"
        case fibonacciPullback:
            return "피보나치 되돌림"
        case doubleTopBottom:
            return "더블탑/바텀"
        case candleQuality:
            return "신호봉 품질"
        default:
            return id
        }
    }
}

struct SignalConfirmationEngine {
    private let rules: [any SignalConfirmationRule]

    init(rules: [any SignalConfirmationRule] = SignalConfirmationEngine.defaultRules) {
        self.rules = rules
    }

    func decision(
        for signal: StrategySignal,
        context: StrategyContext,
        config: SignalConfirmationConfig
    ) -> SignalConfirmationDecision {
        guard config.mode != .off else {
            return SignalConfirmationDecision(
                isAllowed: true,
                score: nil,
                reason: "보조 점수 비활성화"
            )
        }

        let score = score(signal: signal, context: context, config: config)
        guard config.mode == .gate else {
            return SignalConfirmationDecision(
                isAllowed: true,
                score: score,
                reason: "보조 점수 \(score.summaryText) 관찰"
            )
        }

        guard score.isConfirmed else {
            return SignalConfirmationDecision(
                isAllowed: false,
                score: score,
                reason: "보조 점수 \(score.summaryText) 미달"
            )
        }

        return SignalConfirmationDecision(
            isAllowed: true,
            score: score,
            reason: "보조 점수 \(score.summaryText) 통과"
        )
    }

    func decision(
        for signal: StrategySignal,
        context: StrategyContext,
        config: SignalConfirmationConfig,
        profile: SignalConfirmationProfile
    ) -> SignalConfirmationDecision {
        guard config.mode != .off else {
            return SignalConfirmationDecision(
                isAllowed: true,
                score: nil,
                reason: "보조지표 프로파일 비활성화"
            )
        }

        let fullScore = score(signal: signal, context: context, config: config)
        let profileScore = score(
            evidences: fullScore.evidences.filter { profile.evidenceIDs.contains($0.id) },
            requiredScore: config.requiredScore,
            config: config
        )

        guard profile.isActive else {
            return SignalConfirmationDecision(
                isAllowed: true,
                score: profileScore,
                reason: profile.inactiveReason ?? "전용 보조지표 적용 없음"
            )
        }

        guard config.mode == .gate else {
            return SignalConfirmationDecision(
                isAllowed: true,
                score: profileScore,
                reason: "전용 보조지표 \(profile.name) 관찰"
            )
        }

        let positiveEvidenceIDs = Set(profileScore.evidences.filter { $0.score > 0 }.map(\.id))
        let missingHardGateIDs = profile.hardGateEvidenceIDs.subtracting(positiveEvidenceIDs)
        guard missingHardGateIDs.isEmpty else {
            let names = missingHardGateIDs
                .sorted()
                .map(SignalConfirmationEvidenceID.displayName)
                .joined(separator: ", ")
            return SignalConfirmationDecision(
                isAllowed: false,
                score: profileScore,
                reason: "전용 보조지표 \(profile.name) 미충족: \(names)"
            )
        }

        let softMatches = profile.softGateEvidenceIDs.intersection(positiveEvidenceIDs).count
        guard softMatches >= profile.minimumSoftMatchesToAllow else {
            return SignalConfirmationDecision(
                isAllowed: false,
                score: profileScore,
                reason: "전용 보조지표 \(profile.name) 미충족: 보조 동조 \(softMatches)/\(profile.minimumSoftMatchesToAllow)"
            )
        }

        let riskMultiplier = profile.maximumRiskMultiplier(softMatches: softMatches)
        return SignalConfirmationDecision(
            isAllowed: true,
            score: profileScore,
            reason: "전용 보조지표 \(profile.name) 통과, 보조 동조 \(softMatches), 리스크 \(riskMultiplier * 100)%",
            maximumRiskPerTradeMultiplier: riskMultiplier
        )
    }

    func score(
        signal: StrategySignal,
        context: StrategyContext,
        config: SignalConfirmationConfig
    ) -> SignalConfirmationScore {
        let evidences = rules.compactMap {
            $0.evaluate(baseSignal: signal, context: context)
        }
        return score(
            evidences: evidences,
            requiredScore: config.requiredScore,
            config: config
        )
    }

    private func score(
        evidences: [SignalEvidence],
        requiredScore: Decimal,
        config: SignalConfirmationConfig
    ) -> SignalConfirmationScore {
        let rawScore = evidences.reduce(Decimal(0)) { $0 + $1.score }
        let groupedScores = Dictionary(grouping: evidences, by: \.group)
            .mapValues { values in
                values.reduce(Decimal(0)) { $0 + $1.score }
            }
        let totalScore = groupedScores.reduce(Decimal(0)) { partial, item in
            let cap = config.groupScoreCaps[item.key] ?? 100
            let cappedPositive = min(max(item.value, 0), cap)
            let negative = min(item.value, 0)
            return partial + cappedPositive + negative
        }

        return SignalConfirmationScore(
            totalScore: totalScore,
            rawScore: rawScore,
            requiredScore: requiredScore,
            evidences: evidences.sorted { lhs, rhs in
                if lhs.group.rawValue == rhs.group.rawValue {
                    return lhs.id < rhs.id
                }
                return lhs.group.rawValue < rhs.group.rawValue
            }
        )
    }

    private static var defaultRules: [any SignalConfirmationRule] {
        [
            TrendAlignmentConfirmationRule(),
            SupportResistanceConfirmationRule(),
            MomentumConfirmationRule(),
            VolumeConfirmationRule(),
            VolatilityConfirmationRule(),
            FibonacciPullbackConfirmationRule(),
            DoubleTopBottomConfirmationRule(),
            CandleQualityConfirmationRule()
        ]
    }
}

extension StrategySignal {
    func addingConfirmation(_ score: SignalConfirmationScore?) -> StrategySignal {
        guard let score else { return self }
        let evidenceText = score.evidences
            .prefix(3)
            .map { "\($0.id) \($0.score.riskText)" }
            .joined(separator: ", ")
        let suffix = evidenceText.isEmpty
            ? "보조점수 \(score.summaryText)"
            : "보조점수 \(score.summaryText) [\(evidenceText)]"

        return StrategySignal(
            id: id,
            strategyID: strategyID,
            symbol: symbol,
            side: side,
            entryPrice: entryPrice,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            reason: "\(reason) | \(suffix)",
            generatedAt: generatedAt
        )
    }
}

private struct TrendAlignmentConfirmationRule: SignalConfirmationRule {
    let id = SignalConfirmationEvidenceID.trendAlignment

    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence? {
        let candles = context.closedCandles
        guard candles.count >= 50,
              let ma25 = candles.simpleMovingAverage(period: 25),
              let ma50 = candles.simpleMovingAverage(period: 50) else {
            return nil
        }

        let close = candles.last?.close ?? baseSignal.entryPrice
        let ma100 = candles.simpleMovingAverage(period: 100)
        let ma50Previous = candles.simpleMovingAverage(period: 50, endingAt: candles.count - 6)
        var score: Decimal = 0

        switch baseSignal.side {
        case .buy:
            if close > ma25, ma25 > ma50 {
                score += 12
            } else if close < ma50 {
                score -= 12
            }
            if let ma100, ma50 > ma100 {
                score += 5
            } else if let ma100, ma50 < ma100 {
                score -= 5
            }
            if let ma50Previous, ma50 > ma50Previous {
                score += 4
            }
        case .sell:
            if close < ma25, ma25 < ma50 {
                score += 12
            } else if close > ma50 {
                score -= 12
            }
            if let ma100, ma50 < ma100 {
                score += 5
            } else if let ma100, ma50 > ma100 {
                score -= 5
            }
            if let ma50Previous, ma50 < ma50Previous {
                score += 4
            }
        }

        guard score != 0 else { return nil }
        return SignalEvidence(
            id: id,
            group: .trend,
            score: score,
            reason: "MA25/50/100 배열과 MA50 기울기"
        )
    }
}

private struct SupportResistanceConfirmationRule: SignalConfirmationRule {
    let id = SignalConfirmationEvidenceID.supportResistance

    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence? {
        let candles = context.closedCandles
        guard candles.count >= 20,
              let atr = candles.averageTrueRange(period: 14),
              atr > 0 else {
            return nil
        }

        let recent = Array(candles.suffix(20))
        let support = recent.map(\.low).min() ?? baseSignal.entryPrice
        let resistance = recent.map(\.high).max() ?? baseSignal.entryPrice
        let distance: Decimal
        let reason: String

        switch baseSignal.side {
        case .buy:
            distance = (baseSignal.entryPrice - support) / atr
            reason = "최근 20봉 지지선과 ATR 거리"
        case .sell:
            distance = (resistance - baseSignal.entryPrice) / atr
            reason = "최근 20봉 저항선과 ATR 거리"
        }

        let score: Decimal
        if distance >= 0, distance <= Decimal(string: "1.4")! {
            score = 10
        } else if distance > Decimal(string: "1.4")!, distance <= Decimal(string: "2.2")! {
            score = 5
        } else {
            score = -6
        }

        return SignalEvidence(id: id, group: .structure, score: score, reason: reason)
    }
}

private struct MomentumConfirmationRule: SignalConfirmationRule {
    let id = SignalConfirmationEvidenceID.rsiMomentum

    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence? {
        let candles = context.closedCandles
        guard let rsi = candles.relativeStrengthIndex(period: 14),
              let previousRSI = candles.relativeStrengthIndex(period: 14, endingAt: candles.count - 2) else {
            return nil
        }

        let score: Decimal
        switch baseSignal.side {
        case .buy:
            if rsi >= 38, rsi <= 64, rsi >= previousRSI {
                score = 8
            } else if rsi > 74 {
                score = -8
            } else {
                score = 0
            }
        case .sell:
            if rsi >= 36, rsi <= 62, rsi <= previousRSI {
                score = 8
            } else if rsi < 26 {
                score = -8
            } else {
                score = 0
            }
        }

        guard score != 0 else { return nil }
        return SignalEvidence(id: id, group: .momentum, score: score, reason: "RSI14 위치와 방향")
    }
}

private struct VolumeConfirmationRule: SignalConfirmationRule {
    let id = SignalConfirmationEvidenceID.volumeExpansion

    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence? {
        let candles = context.closedCandles
        guard candles.count >= 21,
              let latest = candles.last,
              let averageVolume = candles.averageVolume(period: 20, endingAt: candles.count - 2),
              averageVolume > 0 else {
            return nil
        }

        let ratio = latest.volume / averageVolume
        let score: Decimal
        if ratio >= Decimal(string: "1.25")! {
            score = 6
        } else if ratio < Decimal(string: "0.6")! {
            score = -4
        } else {
            score = 2
        }

        return SignalEvidence(id: id, group: .volume, score: score, reason: "20봉 평균 대비 거래량")
    }
}

private struct VolatilityConfirmationRule: SignalConfirmationRule {
    let id = SignalConfirmationEvidenceID.atrRegime

    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence? {
        let candles = context.closedCandles
        guard let atr = candles.averageTrueRange(period: 14),
              baseSignal.entryPrice > 0 else {
            return nil
        }

        let atrPercent = atr / baseSignal.entryPrice * 100
        let score: Decimal
        if atrPercent >= Decimal(string: "0.25")!, atrPercent <= Decimal(string: "6.5")! {
            score = 5
        } else if atrPercent > Decimal(string: "9")! {
            score = -10
        } else {
            score = -3
        }

        return SignalEvidence(id: id, group: .volatility, score: score, reason: "ATR14 변동성 구간")
    }
}

private struct FibonacciPullbackConfirmationRule: SignalConfirmationRule {
    let id = SignalConfirmationEvidenceID.fibonacciPullback

    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence? {
        let candles = context.closedCandles
        guard candles.count >= 34 else { return nil }
        let recent = Array(candles.suffix(55))
        guard let high = recent.map(\.high).max(),
              let low = recent.map(\.low).min(),
              high > low else {
            return nil
        }

        let range = high - low
        let ratio: Decimal
        switch baseSignal.side {
        case .buy:
            ratio = (high - baseSignal.entryPrice) / range
        case .sell:
            ratio = (baseSignal.entryPrice - low) / range
        }

        let score: Decimal
        if ratio >= Decimal(string: "0.382")!, ratio <= Decimal(string: "0.618")! {
            score = 8
        } else if ratio >= Decimal(string: "0.236")!, ratio <= Decimal(string: "0.786")! {
            score = 4
        } else {
            return nil
        }

        return SignalEvidence(id: id, group: .structure, score: score, reason: "최근 스윙의 피보나치 되돌림")
    }
}

private struct DoubleTopBottomConfirmationRule: SignalConfirmationRule {
    let id = SignalConfirmationEvidenceID.doubleTopBottom

    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence? {
        let candles = context.closedCandles
        guard candles.count >= 24,
              let atr = candles.averageTrueRange(period: 14),
              atr > 0 else {
            return nil
        }

        let recent = Array(candles.suffix(30))
        switch baseSignal.side {
        case .buy:
            return matchingTwoExtremes(
                candles: recent,
                atr: atr,
                value: \.low,
                isLowPattern: true
            ).map {
                SignalEvidence(id: id, group: .pattern, score: $0, reason: "더블바텀 유사 저점 구조")
            }
        case .sell:
            return matchingTwoExtremes(
                candles: recent,
                atr: atr,
                value: \.high,
                isLowPattern: false
            ).map {
                SignalEvidence(id: id, group: .pattern, score: $0, reason: "더블탑 유사 고점 구조")
            }
        }
    }

    private func matchingTwoExtremes(
        candles: [Candle],
        atr: Decimal,
        value: KeyPath<Candle, Decimal>,
        isLowPattern: Bool
    ) -> Decimal? {
        let indexedValues = candles.enumerated().map { ($0.offset, $0.element[keyPath: value]) }
        let sorted = indexedValues.sorted {
            isLowPattern ? $0.1 < $1.1 : $0.1 > $1.1
        }

        guard let first = sorted.first else { return nil }
        for candidate in sorted.dropFirst().prefix(8) {
            guard abs(first.0 - candidate.0) >= 4 else { continue }
            let distance = absoluteDecimal(first.1 - candidate.1)
            if distance <= atr * Decimal(string: "0.65")! {
                return 8
            }
        }
        return nil
    }
}

private struct CandleQualityConfirmationRule: SignalConfirmationRule {
    let id = SignalConfirmationEvidenceID.candleQuality

    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence? {
        guard let latest = context.closedCandles.last else { return nil }

        let score: Decimal
        switch baseSignal.side {
        case .buy:
            if latest.isBullish, latest.closeLocation >= Decimal(string: "0.65")! {
                score = 5
            } else if latest.isBearish, latest.closeLocation <= Decimal(string: "0.35")! {
                score = -4
            } else {
                return nil
            }
        case .sell:
            if latest.isBearish, latest.closeLocation <= Decimal(string: "0.35")! {
                score = 5
            } else if latest.isBullish, latest.closeLocation >= Decimal(string: "0.65")! {
                score = -4
            } else {
                return nil
            }
        }

        return SignalEvidence(id: id, group: .pattern, score: score, reason: "신호봉 종가 위치와 몸통 방향")
    }
}

private extension Array where Element == Candle {
    func simpleMovingAverage(period: Int, endingAt endIndex: Int? = nil) -> Decimal? {
        guard period > 0, !isEmpty else { return nil }
        let end = Swift.min(endIndex ?? count - 1, count - 1)
        let start = end - period + 1
        guard start >= 0, end < count else { return nil }
        return self[start...end].reduce(Decimal(0)) { $0 + $1.close } / Decimal(period)
    }

    func averageVolume(period: Int, endingAt endIndex: Int? = nil) -> Decimal? {
        guard period > 0, !isEmpty else { return nil }
        let end = Swift.min(endIndex ?? count - 1, count - 1)
        let start = end - period + 1
        guard start >= 0, end < count else { return nil }
        return self[start...end].reduce(Decimal(0)) { $0 + $1.volume } / Decimal(period)
    }

    func averageTrueRange(period: Int, endingAt endIndex: Int? = nil) -> Decimal? {
        guard period > 0, count >= 2 else { return nil }
        let end = Swift.min(endIndex ?? count - 1, count - 1)
        let start = end - period + 1
        guard start >= 1, end < count else { return nil }

        let total = (start...end).reduce(Decimal(0)) { partial, index in
            let candle = self[index]
            let previousClose = self[index - 1].close
            let trueRange = Swift.max(
                candle.high - candle.low,
                Swift.max(
                    absoluteDecimal(candle.high - previousClose),
                    absoluteDecimal(candle.low - previousClose)
                )
            )
            return partial + trueRange
        }
        return total / Decimal(period)
    }

    func relativeStrengthIndex(period: Int, endingAt endIndex: Int? = nil) -> Decimal? {
        guard period > 0, count >= period + 1 else { return nil }
        let end = Swift.min(endIndex ?? count - 1, count - 1)
        let start = end - period + 1
        guard start >= 1, end < count else { return nil }

        var gains: Decimal = 0
        var losses: Decimal = 0
        for index in start...end {
            let delta = self[index].close - self[index - 1].close
            if delta >= 0 {
                gains += delta
            } else {
                losses += absoluteDecimal(delta)
            }
        }

        let averageGain = gains / Decimal(period)
        let averageLoss = losses / Decimal(period)
        let denominator = averageGain + averageLoss
        guard denominator > 0 else { return 50 }
        return averageGain / denominator * 100
    }
}

private extension Candle {
    var isBullish: Bool {
        close > open
    }

    var isBearish: Bool {
        close < open
    }

    var closeLocation: Decimal {
        let range = high - low
        guard range > 0 else { return Decimal(string: "0.5")! }
        return (close - low) / range
    }
}
