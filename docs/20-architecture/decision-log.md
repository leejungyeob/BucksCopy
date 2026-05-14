# Decision Log

## 한글 요약

- 이 문서는 `BucksCopy`의 구조/정책 결정을 짧게 기록하는 ADR-lite 문서입니다.
- 세부 설계서보다 “왜 이 방향을 정했는지”를 남기는 데 집중합니다.

## 기록 형식

```markdown
## 000X. 제목
- Status: proposed | accepted | deprecated
- Date: YYYY-MM-DD
- Context:
- Decision:
- Consequences:
```

## 0001. Codex Foundation v1 도입

- Status: accepted
- Date: 2026-05-13
- Context:
  - 저장소가 거의 빈 상태에서 macOS 자동매매 앱 개발을 시작합니다.
  - 안정적인 코드 생성을 위해 repo-local 규칙, 스킬, 에이전트, 하네스를 먼저 고정해야 합니다.
- Decision:
  - SwiftUI 네이티브 macOS + Tuist/Xcode + Bitget USDT Futures + Paper trading 우선을 기본값으로 둡니다.
  - `AGENTS.md`와 `docs/`를 canonical 문서 세트로 둡니다.
  - `.codex/skills`, `.codex/agents`, `scripts/ci`로 스킬/에이전트/trace 하네스를 구성합니다.
- Consequences:
  - 이후 구현 작업은 레이어 경계와 Paper-first 안전 규칙을 기준으로 판단합니다.
  - live trading은 별도 decision log와 보안 리뷰 전까지 기본 차단입니다.

## 0002. Paper Trading First

- Status: accepted
- Date: 2026-05-13
- Context:
  - 자동매매 프로그램은 credential, 주문, 손실 가능성이 직접 연결되는 고위험 도메인입니다.
  - 초기에는 candle/strategy/order intent가 재현 가능하게 검증되는 것이 live execution보다 중요합니다.
- Decision:
  - v1 문서와 하네스는 Paper trading을 기본 실행 모드로 둡니다.
  - live order execution은 명시적인 future policy switch, security review, acceptance test 없이는 구현하지 않습니다.
- Consequences:
  - Strategy와 order execution은 paper/live boundary contract를 분리해야 합니다.
  - UI에 API credential 입력이 있어도 즉시 live 주문을 허용하지 않습니다.

## 0003. USDT-M Futures Watchlist Scope

- Status: accepted
- Date: 2026-05-13
- Context:
  - 사용자는 Bitget USDT-M Futures에 있는 코인들을 거래 대상으로 삼습니다.
  - 전체 USDT-M Futures를 자동 구독/매매하면 WebSocket 안정성, 리스크 관리, 전략 검증 범위가 급격히 커집니다.
- Decision:
  - v1 상품 범위는 Bitget Classic Futures v2 mix API의 `productType=USDT-FUTURES`로 고정합니다.
  - contract config 요청은 BTCUSDT/ETHUSDT 각각의 `symbol` 파라미터로 호출하고, 앱 catalog와 Watchlist에도 두 심볼만 보관합니다.
  - Watchlist 후보는 `symbolStatus=normal`이고 `supportMarginCoins`에 `USDT`가 있는 BTCUSDT/ETHUSDT로 제한합니다.
  - WebSocket 구독은 Watchlist 심볼만 대상으로 하며, 한 연결당 50개 이하 채널을 기본 제한으로 둡니다.
- Consequences:
  - Symbol catalog와 Watchlist는 Domain contract와 Data repository 경계로 분리합니다.
  - Watchlist에 없는 심볼은 strategy 실행이나 paper order intent 생성 대상이 아닙니다.
  - live order endpoint는 계속 disabled 상태로 유지합니다.

## 0004. Layer Simplification and Local Market History

- Status: accepted
- Date: 2026-05-13
- Context:
  - 초기 앱 구현 전에는 과한 레이어 수가 코드 생성과 파일 배치를 더 어렵게 만들 수 있습니다.
  - Bitget candle API는 현재 시점 기준으로 조회 가능한 기간과 요청 수량에 제한이 있으므로, 앱이 장기간 안정적으로 전략을 평가하려면 로컬 히스토리 누적이 필요합니다.
- Decision:
  - 필수 레이어는 `App / Presentation / Domains / Data`로 단순화합니다.
  - 기존 `Features` 명칭은 SwiftUI 화면/상태 책임을 더 명확히 하기 위해 `Presentation`으로 바꿉니다.
  - `Service`, `Platform`, `Core`, `UIShared`는 별도 최상위 레이어로 만들지 않고 필요 시 네 레이어 내부의 하위 폴더/타입으로 둡니다.
  - Watchlist 심볼의 closed candle은 SQLite-backed local market history store에 지속 저장합니다.
  - 앱 재시작 시 로컬 마지막 closed candle 이후의 gap만 Bitget REST로 보충하고, 이후 WebSocket으로 계속 누적합니다.
- Consequences:
  - API credential은 Keychain-facing Data adapter만 소유하고, 로컬 market history DB에는 비밀정보를 저장하지 않습니다.
  - 거래 의사결정의 핵심 장기 데이터는 거래소에서 매번 다시 받는 데이터가 아니라 로컬에 누적된 closed candle history입니다.
  - 이전 paper/live 거래기록은 전략 디버깅과 감사 목적의 최소 기록으로 남길 수 있지만, candle history와 별도 정책으로 관리합니다.

## 0005. Dashboard v1 and Paper-Only Execution

- Status: accepted
- Date: 2026-05-13
- Context:
  - 사용자는 로그인보다 API credential 입력, candle chart, 현재 포지션, 자동매매 로그, 전략 설정을 한 화면에서 확인하길 원합니다.
  - 실제 주문은 아직 위험하므로 UI가 붙어도 주문 실행은 Paper로 제한해야 합니다.
- Decision:
  - Dashboard v1은 통합 SwiftUI 화면으로 구성합니다.
  - Bitget private API credential은 `APIKey`, `SecretKey`, `Passphrase` 세 값을 받고 Keychain-facing Data adapter에만 저장합니다.
  - Candle chart는 SwiftUI Canvas로 구현하고 `15m`, `1H`, `4H`, `12H`, `1D` 선택을 지원합니다.
  - 현재 포지션은 `GET /api/v2/mix/position/all-position`을 통해 읽기 전용으로 표시합니다.
  - 자동매매 시작은 Paper runner만 실행하며, strategy registry를 먼저 둡니다.
- Consequences:
  - 모든 실제 내장 전략은 signal 생성 시 `entryPrice`, `stopLoss`, `takeProfit`을 함께 제공해야 합니다.
  - `POST /api/v2/mix/order/place-order`와 TPSL order API는 계속 disabled 상태입니다.
  - Bot event, signal, paper order, risk decision 로그는 SQLite local DB에 영구 저장합니다.

## 0006. Manual Background Backtesting and Risk-Gated Built-In Strategies

- Status: accepted
- Date: 2026-05-14
- Context:
  - 백테스트 UI를 추가한 뒤 앱 시작/전략 선택 UI에서 체감 렉이 발생했습니다.
  - 사용자는 BTCUSDT/ETHUSDT, 전략, 시간봉을 직접 고르고, 결과를 한국어 지표로 이해하길 원합니다.
  - 백테스트는 많은 로컬 candle을 읽고 전략을 반복 평가하므로 SwiftUI 메인 스레드에서 실행하면 안 됩니다.
- Decision:
  - 백테스트는 앱 시작 시 자동 실행하지 않고, 사용자가 버튼을 누를 때만 실행합니다.
  - candle 로드와 전략 평가는 `Task.detached` 백그라운드 작업에서 수행하고, 결과 반영만 MainActor에서 처리합니다.
  - 백테스트 설정 UI는 menu picker 대신 버튼/리스트 기반 선택 컨트롤을 사용합니다.
  - 자동매매/백테스트 공통 risk policy는 최대 레버리지 `10x`, 최소 손익비 `2:1`, 레버리지 반영 손절 위험 `< 30%`를 강제합니다. 이 손절 위험 차단은 0012에서 포지션 사이징으로 대체되었습니다.
  - 내장 전략은 막힘봉 숏 단일 전략으로 구성하고, 이전 broad indicator 전략은 로컬 백테스트 edge가 확인될 때까지 제거합니다.
- Consequences:
  - 백테스트 결과는 실제 로컬 candle 상태에 따라 달라지며, 50% 승률은 보장값이 아니라 앱에서 검증해야 하는 결과 기준입니다.
  - live order는 계속 비활성화하며, risk policy 통과는 Paper/backtest 허용 조건일 뿐 실거래 승인 조건이 아닙니다.
  - UI 패널 증가는 왼쪽 ScrollView와 compact BTC/ETH Watchlist로 흡수합니다.

## 0007. Fee-Aware Paper and Backtest Risk Policy

- Status: accepted
- Date: 2026-05-14
- Context:
  - 백테스트 수익률이 거래 수수료를 반영하지 않으면 저폭 익절 전략의 기대값이 과대평가됩니다.
  - 사용자는 레퍼럴 등록 기준 수수료를 반영하고, 익절 후에도 수수료보다 이익이 커야 한다는 조건을 요구했습니다.
- Decision:
  - Bitget futures fee를 Paper/backtest 공통 정책으로 사용하되, 진입 시장가=taker, 익절 예약 limit=maker, 손절 trigger market=taker로 구분합니다.
  - 레퍼럴 등록 할인은 중앙 `TradingFeePolicy` 상수로 분리하고, 실제 계정 수수료 조회가 붙기 전까지 기본 할인 가정으로 계산합니다.
  - risk policy는 최소 `2:1` 손익비, 레버리지 반영 손절 위험 `< 30%`, 익절 기대 수익 `> 진입 taker + 익절 maker 수수료`를 모두 만족해야 통과합니다. 이 손절 위험 차단은 0012에서 포지션 사이징으로 대체되었습니다.
  - maker 체결은 주문이 호가창에 머물러 유동성을 공급한 경우에만 인정하며, 실제 체결 로그가 붙기 전까지 결과 해석에 주의합니다.
- Consequences:
  - 백테스트 `netReturnPercent`와 trade return은 수수료 차감 후 값입니다.
  - 승리 거래는 진입 taker + 익절 maker 수수료를 차감하고, 손실 거래는 진입 taker + 손절 taker 수수료를 차감합니다.
  - 실제 계정의 VIP/BGB/쿠폰/프로모션 수수료가 다르면 `TradingFeePolicy` 또는 향후 계정별 fee source를 교체해야 합니다.

## 0008. Timeframe-Scoped Multi-Strategy Portfolio

- Status: accepted
- Date: 2026-05-14
- Context:
  - 단일 전략만으로는 거래 수가 부족하고, 한 전략이 모든 시간봉에서 좋은 성과를 내기는 어렵습니다.
  - 사용자는 승률과 순손익이 높은 전략을 4-5개 정도 선별하고, 각 시간봉마다 성과가 검증된 여러 전략을 동시에 운용하려고 합니다.
- Decision:
  - 전략 활성화 단위는 `strategy × timeframe` 조합으로 둡니다.
  - 한 시간봉에는 여러 전략이 동시에 활성화될 수 있고, 한 전략도 여러 시간봉에서 활성화될 수 있습니다.
  - 후보 조합은 수수료 차감 후 순손익, 승률, 거래 수, 최대 낙폭, 차단 신호 수로 평가합니다.
  - closed candle이 확정되면 해당 symbol/timeframe에 활성화된 모든 전략을 평가할 수 있습니다.
  - 다중 전략 운영 전에는 동일 심볼 중복 진입, 같은 방향 중복 신호, 반대 신호, 기존 포지션 보유 중 재진입 정책을 별도로 정의해야 합니다.
- Consequences:
  - 향후 백테스트는 단일 전략 결과뿐 아니라 조합별 성과와 포트폴리오 합산 성과를 함께 보여줘야 합니다.
  - 거래 수 증가는 목표지만, Watchlist 단위 리스크와 포지션 중복 제한이 없으면 성과보다 손실 변동성이 먼저 커질 수 있습니다.

## 0009. Exchange-Side TP/SL Protection Before Live Execution

- Status: accepted
- Date: 2026-05-14
- Context:
  - 앱이 꺼져도 포지션이 자동 정리되려면 TP/SL이 앱 내부 상태가 아니라 거래소 서버에 예약 주문으로 등록되어야 합니다.
  - 진입 주문 체결 후 TP/SL 등록이 실패하면 포지션이 unprotected 상태로 남는 위험 구간이 생깁니다.
- Decision:
  - live 진입 기능을 켜기 전에 exchange-side TP/SL 보호 주문 경계를 먼저 구현합니다.
  - 진입 체결 후 Bitget `place-tpsl-order`로 TP와 SL을 각각 등록하는 모델을 둡니다.
  - TP는 `profit_plan` + limit `executePrice`, SL은 `loss_plan` + market execution `executePrice=0`으로 모델링합니다.
  - TP/SL 보호 주문 등록 실패 시 실패한 보호 주문별로 최소 5회 재시도합니다.
  - 재시도까지 실패하면 포지션은 protection-failed로 간주하고, future live runner는 즉시 경고와 fail-closed 청산 정책을 적용해야 합니다.
- Consequences:
  - 현재 구현은 보호 주문 도메인 모델, 재시도 installer, Bitget TPSL adapter를 제공하지만 live entry는 계속 비활성화합니다.
  - 실제 활성화 전에는 중복 clientOid, 부분 체결 size, 기존 TP/SL 점유 수량, 앱 재시작 시 보호 주문 복구를 추가 검증해야 합니다.

## 0010. Chart Timeframe Is Not Trading Monitor Scope

- Status: accepted
- Date: 2026-05-14
- Context:
  - 사용자는 15분봉 차트를 보고 있어도 1H/4H/12H/1D 조건이 동시에 충족되면 자동매매가 즉시 반응하길 원합니다.
  - 이전 Dashboard Paper 시작 경로는 선택된 `symbol/timeframe/strategy`만 한 번 평가하므로, 화면 선택값이 실행 범위를 제한했습니다.
- Decision:
  - Paper monitor는 Watchlist의 모든 심볼과 지원 시간봉 전체를 순회합니다.
  - 각 시간봉은 `StrategyTimeframeRouting`이 추천하는 전략 목록을 평가합니다.
  - 같은 `symbol/timeframe/strategy/closed candle open time` 조합은 한 번만 평가해 중복 Paper order를 막습니다.
  - 화면의 chart timeframe은 표시와 설정 컨텍스트일 뿐, 실행 중 Paper monitor의 감시 범위를 제한하지 않습니다.
- Consequences:
  - Paper 실행 중 REST candle backfill과 로컬 candle read가 시간봉별로 늘어나므로, 향후 Watchlist가 커지면 rate-limit와 스케줄링 정책을 추가해야 합니다.
  - live execution이 켜지기 전에는 동일 심볼의 다중 전략 신호를 실제 포지션으로 합치는 정책을 별도로 확정해야 합니다.

## 0011. Backtest Uses Compounded Balance

- Status: accepted
- Date: 2026-05-14
- Context:
  - 사용자는 단순 수익률 합산이 아니라 시작금액이 거래마다 증감되는 최종 잔고 기준 백테스트를 요구했습니다.
  - 기존 엔진은 거래별 net leveraged return percent를 단순 합산해 `netReturnPercent`를 계산했습니다.
- Decision:
  - 백테스트 설정에 시작금액을 둡니다.
  - 각 거래는 현재 잔고에 수수료 차감 후 레버리지 반영 수익률을 적용해 다음 거래의 시작 잔고를 만듭니다.
  - `netReturnPercent`는 `(finalBalance - initialCapital) / initialCapital`로 계산합니다.
  - 포지션 보유 중 지나간 candle은 신규 신호 평가는 건너뛰되, 청산 후 지표 history에는 포함합니다.
- Consequences:
  - UI의 순손익은 최종 잔고 기준 수익률과 금액을 함께 보여줍니다.
  - 기존 단순 합산 수익률과 결과가 달라질 수 있으며, 장기 지표 전략은 이전보다 더 정확한 history로 평가됩니다.

## 0012. Position Sizing By Per-Trade Account Risk

- Status: accepted
- Date: 2026-05-14
- Context:
  - 레버리지가 높아질수록 기존 `손절폭 × 레버리지 < 30%` 차단 정책 때문에 좋은 신호도 거래 0건으로 떨어질 수 있습니다.
  - 사용자는 연속 손실/일일 손실 정지형 가드레일보다, 진입마다 손실 한도를 맞추는 방식을 선호했습니다.
- Decision:
  - 1회 최대 손실률을 전략 설정으로 둡니다.
  - 기본값은 `12%`, UI에서 설정 가능한 최대값은 `15%`로 제한합니다.
  - 손절폭이 큰 신호는 차단하지 않고 `포지션 투입비율 = 최대 손실률 / (손절폭 × 레버리지)`로 축소합니다.
  - 백테스트 수익률과 수수료는 포지션 투입비율만큼 계좌 기준으로 스케일링합니다.
- Consequences:
  - 레버리지는 계좌 전체 손실을 키우는 장치가 아니라 증거금 효율을 조절하는 장치로 취급됩니다.
  - 손절폭이 넓은 전략은 거래가 차단되지는 않지만 투입비율이 낮아져 기대수익도 함께 낮아집니다.
  - 실제 live 적용 전에는 최소 주문금액과 계약 수량 반올림 검증이 추가로 필요합니다.

## 0013. Confirmation Scoring Before Risk Policy

- Status: accepted
- Date: 2026-05-14
- Context:
  - 사용자는 헤드앤숄더, 피보나치, 더블탑 같은 기본 매매법을 메인 전략으로 쓰기보다, 메인 전략 신호의 확률 가중치를 높이는 보조 근거로 쓰길 원했습니다.
  - 보조지표를 많이 붙이면 RSI/MACD/Stochastic처럼 같은 정보를 중복 계산하는 과최적화 위험이 있습니다.
- Decision:
  - 메인 전략이 먼저 `StrategySignal`을 만들고, risk policy 전에 `SignalConfirmationEngine`이 보조 점수를 계산합니다.
  - 기본 보조 점수는 추세, 구조, 패턴, 모멘텀, 거래량, 변동성 그룹으로 나누고 그룹별 cap을 적용합니다.
  - confirmation mode는 `OFF`, `Observe`, `Gate`로 나눕니다. `Observe`는 점수와 구간별 성과만 기록하고, `Gate`만 threshold 미달 signal을 `confirmation-blocked`로 차단합니다.
  - 기본 mode는 `OFF`입니다. primary backtest 결과는 항상 메인 전략 단독 결과와 일치해야 하므로 보조 점수는 기본 계산 경로에서 제외합니다.
  - Gate threshold 22점은 초기 휴리스틱 후보일 뿐이며, 기본 차단 정책으로 고정하지 않습니다.
  - 백테스트는 같은 candle set에서 confirmation `OFF`, `Observe`, `Gate` 결과를 함께 계산해 순손익, 승률, 거래 수, MDD 차이를 비교할 수 있습니다.
  - 백테스트는 Gate threshold 후보를 스캔하고, OFF보다 순손익이 개선되며 최소 거래 수를 만족하는 후보가 있을 때만 Gate 기준점을 추천합니다.
  - 보조 점수 비교를 켜도 primary result/log는 `OFF` 결과를 사용하고, Observe/Gate 결과는 비교표에만 표시합니다.
- Consequences:
  - confirmation layer는 승률 보장 장치가 아니라 기대값 개선 여부를 검증하기 위한 관찰/필터 레이어입니다.
  - 기본 가중치는 휴리스틱이며, 실제 최적화는 로컬 closed candle 백테스트와 walk-forward 결과로 조정해야 합니다.
  - live order는 계속 비활성화하며, confirmation 통과는 Paper/backtest 허용 조건일 뿐 실거래 승인 조건이 아닙니다.

## 0014. Strategy-Timeframe Confirmation Profiles

- Status: accepted
- Date: 2026-05-14
- Context:
  - 전역 보조 점수 Gate는 일부 조합에서 OFF보다 성과가 악화되었습니다.
  - 사용자는 메인 전략과 보조지표의 동조/비동조 성과를 비교한 뒤, 각 `strategy × timeframe`에 맞는 보조지표만 적용하길 원했습니다.
  - 특히 `4H 이평선 정역배열 + MA 추세 정렬`은 표본이 작아도 비동조 손실이 커서 즉시 강한 Gate로 반영하기로 했습니다.
- Decision:
  - 보조지표 적용은 전역 점수제가 아니라 `SignalConfirmationProfile`로 정의합니다.
  - `Hard Gate`는 지정 evidence가 양수로 동조하지 않으면 진입을 차단합니다.
  - `Soft Gate`는 최소 동조 수를 만족해야 진입을 허용하고, 동조 개수에 따라 `maximumRiskPerTradePercent`를 낮춰 포지션 크기에 반영합니다.
  - 백테스트 비교의 ON 경로는 추천 `strategy × timeframe` 조합에 대해 전용 프로파일을 사용합니다.
  - 적용 프로파일:
    - `15m 이평선 정역배열`: RSI, 지지/저항, 피보나치 중 1개 이상 동조 필요, 동조 수에 따라 65%/85%/100% 리스크 배율
    - `1H 이평선 정역배열`: MA 추세 정렬 Hard Gate
    - `4H 막힘봉 숏`: 지지/저항, 신호봉 품질 중 1개 이상 동조 필요, 동조 수에 따라 75%/100% 리스크 배율
    - `4H 이평선 정역배열`: MA 추세 정렬 Hard Gate
    - `12H VWMA100 터치 추세`: 보조지표 OFF
    - `1D VWMA100 터치 추세`: 더블탑/바텀 Hard Gate, 피보나치/신호봉 품질 동조 수에 따라 80%/90%/100% 리스크 배율
- Consequences:
  - 백테스트 UI는 `OFF`, `Observe`, `적용`을 같은 candle set에서 비교합니다.
  - 전용 프로파일 적용은 손실 회피를 우선하지만 거래 수 감소와 과최적화 위험을 동반합니다.
  - live order는 계속 비활성화이며, Paper/backtest에서 검증된 뒤 별도 live policy가 필요합니다.
