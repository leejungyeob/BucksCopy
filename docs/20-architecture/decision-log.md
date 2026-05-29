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
  - 기본값은 최초 `12%`였고, 현재 기본값은 0016 결정에 따라 `5%`입니다. UI에서 설정 가능한 최대값은 `15%`로 제한합니다.
  - 손절폭이 큰 신호는 차단하지 않고 `포지션 투입비율 = 최대 손실률 / (손절폭 × 레버리지)`로 축소합니다.
  - 백테스트 수익률과 수수료는 포지션 투입비율만큼 계좌 기준으로 스케일링합니다.
- Consequences:
  - 레버리지는 계좌 전체 손실을 키우는 장치가 아니라 증거금 효율을 조절하는 장치로 취급됩니다.
  - 손절폭이 넓은 전략은 거래가 차단되지는 않지만 투입비율이 낮아져 기대수익도 함께 낮아집니다.
  - 실제 live 적용 전에는 최소 주문금액과 계약 수량 반올림 검증이 추가로 필요합니다.

## 0013. Confirmation Scoring Deprecated As Trading Input

- Status: deprecated
- Date: 2026-05-14
- Context:
  - 보조지표 Gate는 일부 고정 거래 진단에서 좋아 보여도 전체 재시뮬레이션에서는 최종잔고와 경로 안정성을 충분히 개선하지 못했습니다.
  - 사용자는 보조지표 자료를 제거하고 메인 매매전략과 리스크 관리에 집중하기로 했습니다.
- Decision:
  - 보조지표 검증 리포트, 연구 문서, 로컬 검증 스킬을 제거합니다.
  - 기본 자동매매 경로는 메인 전략 단독 신호와 risk policy만 사용합니다.
  - 보조지표는 향후 명확한 재검증 요청 전까지 진입 Gate나 리스크 가중치로 적용하지 않습니다.
- Consequences:
  - 앱 화면은 자동매매 설정, 차트, 포지션, 로그에 집중합니다.
  - 전략 개선은 보조지표보다 손절/익절 구조, 포지션 크기, 보유 시간 같은 리스크 관리에서 먼저 검증합니다.

## 0014. Two-Stage Take Profit With Profit-Lock Stop

- Status: accepted
- Date: 2026-05-14
- Context:
  - 최종 목표가를 잘 잡아도 목표가 직전에 되돌아와 손실로 끝나는 경우가 있습니다.
  - 사용자는 목표가 일부를 먼저 실현하고, 이후 되돌림이 나와도 전체 거래가 손실이 아니라 익절로 끝나는 구조를 원했습니다.
- Decision:
  - 모든 전략 신호의 기존 `takeProfit`은 최종 목표가인 TP2로 유지합니다.
  - TP1은 진입가와 TP2의 중간값으로 두고 포지션 50%를 익절합니다.
  - TP1 체결 후 남은 50%의 stop-loss는 진입가에서 TP2 방향으로 25% 진행한 가격으로 이동합니다.
  - TP2에 도달하면 남은 50%를 익절하고, TP1 이후 되돌림이 나오면 이동된 stop-loss에서 남은 50%를 익절 청산합니다.
- Consequences:
  - 백테스트 승리 거래의 최대 수익은 단일 TP보다 줄지만, TP1 이후 되돌림 거래의 손실 전환을 줄입니다.
  - 수수료 모델은 TP1/TP2는 maker limit, stop-loss는 profit-lock 상태여도 trigger market으로 계산합니다.
  - live entry는 계속 비활성화입니다. 향후 live 활성화 전에는 TP1 체결 감지 후 기존 SL을 취소/재등록하는 주문 상태 머신이 필요합니다.

## 0015. Prune Built-In Strategies To Validated Portfolio

- Status: accepted
- Date: 2026-05-14
- Context:
  - `10x` leverage and `5%` per-trade account-risk backtests showed only six strategy-timeframe combinations met the user's current practical filters after excluding `4H Bollinger 수축 돌파` and returns below `50%`.
  - Keeping weak built-in strategies in the app creates false choices and increases backtest noise.
- Decision:
  - Keep VWMA100 touch trend, Donchian channel breakout, and Time-Series momentum as validated built-in strategy implementations.
  - Keep the then-in-progress 15m X strategy implementation and route it separately while it is being developed.
  - Recommended routing includes `15m X`, `4H Donchian`, `12H VWMA100`, `12H Donchian`, `12H Time-Series`, `1D VWMA100`, and `1D Donchian`.
  - Remove blocked-candle, moving-average alignment, Bollinger, and MACD strategy implementations from the built-in code path.
- Consequences:
  - `1H` no longer has a recommended Paper route until a future strategy passes the same validation bar.
  - At the time of this decision, `15m X` was a development route and was not treated as part of the six validated combinations. See 0017 for the replacement strategy validation.
  - Historical cache/report files may still contain old strategy names, but active code and generated reports use only the pruned built-in registry.
  - Future strategy additions must be validated through the local backtest script before being added to routing.

## 0016. Default Per-Trade Account Risk To 5 Percent

- Status: accepted
- Date: 2026-05-14
- Context:
  - 사용자는 기본 1회 최대 손실률을 더 보수적인 `5%` 기준으로 운용하기로 했습니다.
  - 백테스트 표준 실행과 앱 기본 전략 설정이 서로 다른 리스크 기본값을 쓰면 결과 해석과 Paper 운용이 어긋날 수 있습니다.
- Decision:
  - `StrategyRiskPolicy.defaultMaximumRiskPerTradePercent` 기본값을 `5%`로 둡니다.
  - Split TP 백테스트 리포트 러너의 기본 `--risk` 실행값도 `5%`로 맞춥니다.
  - UI 최대 설정 가능 값은 기존처럼 `15%`로 유지해 명시적인 고위험 검증만 허용합니다.
- Consequences:
  - 동일한 전략 신호라도 기본 포지션 투입비율이 낮아져 손실과 수익이 모두 더 작게 스케일링됩니다.
  - 기존 `12%` 기본값 기준 캐시/리포트는 새 기본 실행 결과와 비교할 때 리스크 조건 차이를 명시해야 합니다.

## 0017. Replace 15m X With Phase-Spread Reclaim

- Status: accepted
- Date: 2026-05-14
- Context:
  - 기존 `15m X` 전략은 `10x` leverage / `5%` per-trade account-risk / 최신 로컬 15m 전체 구간에서 최종 잔고가 사실상 0에 수렴했고, 승률도 50% 기준에 미달했습니다.
  - 사용자는 최근 4년 BTCUSDT 15m candle 기준으로 승률 50% 이상, 초기 $100, `10x` leverage, `5%` 최대 손실 조건을 통과하는 새 X 전략을 원했습니다.
- Decision:
  - `15m X`를 Phase-Spread Reclaim 전략으로 교체합니다.
  - 전략은 `SMA96`과 `SMA384`의 좁은 phase spread에서 추세 방향 pullback이 fast mean을 찍고, 직전 고가/저가를 reclaim하며, candle close location과 volume expansion을 동시에 만족할 때만 진입합니다.
  - 손절은 신호 candle 극값과 `ATR14` buffer를 함께 고려하고, 최종 목표가는 `2R`로 둡니다.
  - 최신 4년 로컬 BTCUSDT 15m 구간 검증 결과: `$100 -> $216.139727`, `+116.14%`, 승률 `72.22%`, 거래 `39/15/54`, MDD `10.96%`, PF `2.02`.
- Consequences:
  - `15m X`는 더 이상 개발 전용 route가 아니라 Paper 후보 route로 유지합니다.
  - 거래 수가 `54`회로 많지 않으므로, 실거래 전에는 다른 심볼/기간 walk-forward와 Paper 관찰을 추가해야 합니다.
  - live entry는 계속 비활성화이며, 기존 보호주문/Keychain/로그 정책을 통과하기 전까지 자동 실거래로 승격하지 않습니다.

## 0018. Add Medium-Frequency 15m X-Frequency Route

- Status: accepted
- Date: 2026-05-14
- Context:
  - 사용자는 기존 X보다 거래 빈도가 높지만 MDD가 과도하지 않도록, 최근 4년 기준 연간 약 50회 거래하는 15분봉 알고리즘으로 목표를 조정했습니다.
  - 기준은 초기 `$100`, `10x` leverage, `5%` per-trade account-risk, BTCUSDT 로컬 15m candle 백테스트입니다.
- Decision:
  - `X-Frequency` 전략을 새 built-in strategy로 추가하고 15m 추천 라우팅에 `X` 다음 후보로 둡니다.
  - 전략은 `X`와 같은 `SMA96/SMA384` phase-spread reclaim 계열이지만, spread gate를 `0.001...0.020`, volume gate를 `1.5x`, reclaim lookback을 `3`봉으로 조정해 빈도와 품질을 균형화합니다.
  - 최신 4년 로컬 BTCUSDT 15m 구간 검증 결과: `$100 -> $276.774724`, `+176.77%`, 승률 `60.19%`, 거래 `130/86/216`, MDD `39.88%`, PF `1.29`.
- Consequences:
  - 거래 수는 약 `54`회/년으로 목표치에 근접하지만, MDD가 `39.88%`라 여전히 중위험 Paper 후보로 취급합니다.
  - 기존 `X`를 첫 번째 15m route로 유지해 기본 선택은 더 낮은 MDD의 전략이 되도록 합니다.
  - live entry는 계속 비활성화이며, 실거래 전에는 포트폴리오 동시신호, 중복 포지션, 심볼 확장, walk-forward 검증이 필요합니다.

## 0019. Portfolio Signal Replacement Priority

- Status: accepted
- Date: 2026-05-14
- Context:
  - 사용자는 Watchlist의 각 시간봉에 추천 전략을 모두 대입하고, 동시에 여러 신호가 나올 때 가장 좋은 하나만 자동매매 대상으로 삼길 원했습니다.
  - 이미 포지션이 진행 중이어도 더 좋은 새 신호가 나오면 기존 포지션을 시장가로 정리하고 새 신호로 진입하는 정책을 요구했습니다.
  - live execution은 아직 승인되지 않았으므로, 이 정책은 우선 Paper monitor의 deterministic decision으로만 적용해야 합니다.
- Decision:
  - Paper monitor는 같은 실행 주기에서 발생한 모든 `strategy × timeframe × symbol` 후보를 먼저 수집한 뒤 포트폴리오 중재 정책에 넘깁니다.
  - 후보 우선순위는 `계획 손익비` 내림차순을 1순위로 두고, 동률이면 `계좌 기준 기대순익 금액` 내림차순, 다시 동률이면 `계좌 손실위험` 오름차순으로 결정합니다.
  - 열려 있는 포지션은 현재 mark price 기준 남은 TP/SL 거리로 `남은 손익비`와 `예상 잔여 수익금`을 계산합니다.
  - 새 후보가 가장 좋은 진행 중 포지션보다 우위면 Paper log에 “기존 포지션 시장가 정리 후 신규 진입 대상” replacement decision을 기록합니다.
  - 진행 중 포지션이 새 후보와 동률이거나 더 좋으면 새 진입은 보류하고 기존 포지션 유지 decision을 기록합니다.
- Consequences:
  - 같은 closed candle 주기에서 여러 전략이 동시에 신호를 내도 Paper order는 하나만 생성됩니다.
  - TP/SL 정보가 없는 기존 포지션은 남은 손익비를 증명할 수 없으므로 최저 비교 우선순위로 취급합니다.
  - 실제 시장가 청산 및 신규 live 진입은 여전히 비활성화입니다. live 전환 전에는 보호주문 해제/재등록, 부분체결, 수량 반올림, 실패 시 fail-closed 절차가 추가 검증되어야 합니다.

## 0020. Explicit-Consent Live Auto Trading

- Status: accepted
- Date: 2026-05-14
- Context:
  - 사용자가 Paper 경로를 제거하고 실제 Bitget API 연결 기반 자동매매 구현을 요청했습니다.
  - 이전 결정(0002, 0005, 0019)은 live execution 승인 전까지 Paper-only를 기본값으로 두었지만, 이제 실거래 전환 정책을 명시적으로 수락해야 합니다.
  - live 전환은 credential, 주문 API, 보호주문, 포지션 청산, 로컬 로그 보안에 직접 영향을 줍니다.
- Decision:
  - Dashboard 자동매매 실행 상태는 `runningLive`로 전환합니다.
  - UI는 Bitget credential 연결 상태와 `실거래 동의` 체크박스가 모두 충족될 때만 `Start Live`를 허용합니다.
  - Live monitor는 Watchlist의 모든 추천 `strategy × timeframe × symbol` 후보를 모은 뒤 포트폴리오 중재 정책으로 단일 후보만 선택합니다.
  - 신규 진입 순서는 `set-leverage -> place-order market -> order detail fill confirmation -> TP1/TP2/SL TPSL registration`입니다.
  - 진행 중 포지션보다 새 후보가 우위이면 `close-positions`로 기존 포지션을 먼저 정리한 뒤 신규 진입을 시도합니다.
  - 보호주문 등록은 실패한 주문별 최소 5회 재시도하며, 진입 체결 후 보호주문 설치가 끝나지 않으면 unprotected로 간주합니다.
  - 보호주문 재시도 소진 시 high-severity risk log를 남기고 `close-positions`로 fail-closed 청산을 시도합니다.
  - 로컬 로그에는 raw credential, raw private response, raw order ID/clientOid를 남기지 않고 주문 식별자는 마스킹합니다.
- Consequences:
  - `POST /api/v2/mix/order/place-order`, `GET /api/v2/mix/order/detail`, `POST /api/v2/mix/account/set-leverage`, `POST /api/v2/mix/order/close-positions`, `POST /api/v2/mix/order/place-tpsl-order`가 active live path에 포함됩니다.
  - Paper-only decision과 Paper monitor 문구는 현행 정책이 아니며, historical decision으로만 유지됩니다.
  - TP1 체결 후 기존 SL을 profit-lock 가격으로 이동하는 주문 상태 머신은 다음 live-hardening 단계의 잔여 리스크입니다.
  - 실제 운용 전에는 소액/테스트 credential로 endpoint 권한, position mode, minimum size rounding, protection order 체결/취소 흐름을 별도 스모크해야 합니다.

## 0021. Verify Position Before Protection And Fail-Closed Close

- Status: accepted
- Date: 2026-05-15
- Context:
  - 실거래 로그에서 TP/SL 보호주문 실패 후 실제로 닫을 포지션이 확인되지 않았는데도 fail-closed 시장가 청산 요청이 이어지는 흐름이 발견됐습니다.
  - Bitget `place-order`/`order detail` 응답만으로는 현재 계정에 닫을 포지션이 존재한다고 단정하면 안 됩니다.
- Decision:
  - Live entry는 market order fill receipt 이후 `GET /api/v2/mix/position/all-position`으로 같은 symbol/side의 실제 open position을 확인한 뒤 보호주문을 설치합니다.
  - fill receipt는 있지만 현재 포지션이 확인되지 않으면 보호주문과 fail-closed 청산을 모두 생략하고 warning risk log를 남깁니다.
  - 보호주문 재시도 소진 후에도 `close-positions` 호출 직전에 포지션을 다시 확인하고, 포지션이 없으면 시장가 청산을 보내지 않습니다.
  - TPSL 주문은 position mode에 맞춰 hedge mode에서는 `long/short`, one-way mode에서는 `buy/sell` holdSide를 사용하고 contract precision에 맞춰 가격/수량을 정규화합니다.
  - 보호주문 실패 로그는 raw private response를 저장하지 않고 sanitized Bitget code/message를 원인 필드에 보존합니다.
- Consequences:
  - “던질 포지션이 없는데 시장가 청산”하는 오작동을 차단합니다.
  - 포지션 조회 API가 일시 실패하면 자동 청산을 보내지 않고 수동 확인 로그를 우선 남깁니다.
  - live smoke test는 fill receipt, position snapshot, TPSL registration, fail-closed skip/close 경로를 함께 확인해야 합니다.

## 0022. Arm Live Monitor Before First Entry

- Status: accepted
- Date: 2026-05-15
- Context:
  - Start Live 직후 이미 저장되어 있던 최신 closed candle 신호가 즉시 실주문으로 이어질 수 있는 흐름이 확인됐습니다.
  - 사용자는 실시간 자동매매 시작 후 새로 확정되는 신호만 진입 대상으로 삼는지 확인을 요구했습니다.
- Decision:
  - Live monitor 시작 시 Watchlist의 각 `symbol × timeframe × recommended strategy` 최신 completed candle key를 먼저 priming 처리합니다.
  - Priming된 completed candle은 이미 평가된 것으로 간주하므로 첫 실행에서 주문 후보로 쓰지 않습니다.
  - 실주문 후보는 Start Live 이후 현재 forming candle 또는 새 completed candle에서 발생한 strategy signal만 허용합니다.
  - Live log에는 priming 완료 route 수와 현재 forming candle부터 신규 진입 가능 상태를 남깁니다.
- Consequences:
  - 앱 시작/Live 시작 직후 과거 신호로 즉시 포지션을 잡는 오작동을 차단합니다.
  - 0023 이후 Live monitor는 현재 forming candle을 후보로 평가할 수 있지만, 이 priming 정책은 이미 completed된 과거 candle 신호를 막는 용도로 유지합니다.
  - Live monitor 테스트는 startup priming과 forming/completed candle 진입을 분리해 검증해야 합니다.

## 0023. Live Forming Candle Signal Evaluation

- Status: accepted
- Date: 2026-05-15
- Context:
  - 사용자는 실시간 자동매매에서 현재 진행 중인 candle도 가격 조건이 충족되면 진입 후보로 봐야 한다고 판단했습니다.
  - Closed-candle-only 정책은 재현성이 높지만, 15m/4H/12H 신호가 확정될 때까지 기다려 초기 진입이 늦어지는 문제가 있습니다.
  - 진행 중 candle은 이후 가격 변동으로 신호가 사라질 수 있으므로 live path에서만 명시적으로 모델링해야 합니다.
- Decision:
  - Backtest engine은 계속 closed candle만 소비합니다.
  - Live monitor는 `openTime <= now < openTime + timeframe.duration`인 forming candle을 최신 후보 candle로 포함합니다.
  - Start Live priming은 최신 completed candle만 평가완료 처리하고, 현재 forming candle은 priming하지 않습니다.
  - Forming candle에서 `no signal`이 나온 경우 해당 candle key를 평가완료로 잠그지 않습니다. 같은 candle이 업데이트되어 나중에 signal이 생기면 다시 평가합니다.
  - Forming candle에서 risk/confirmation을 통과한 signal이 한 번 후보가 되면 같은 `symbol/timeframe/strategy/openTime` key는 중복 주문 방지를 위해 평가완료 처리합니다.
- Consequences:
  - Live entry는 더 빨라질 수 있지만, closed candle backtest와 live 진입 타점은 의도적으로 달라질 수 있습니다.
  - 진행 중 candle의 high/low/close가 변하면서 생기는 false positive는 portfolio arbitration, risk policy, protection order로 제한합니다.
  - Live monitor 테스트는 forming candle signal, forming no-signal re-evaluation, completed candle duplicate prevention을 함께 검증해야 합니다.

## 0024. Three-Second Live Monitor Cadence And Chart Protection Levels

- Status: accepted
- Date: 2026-05-15
- Context:
  - 사용자는 진행 중 candle 조건이 짧게 나타났다 사라질 수 있으므로 30초 감시 주기가 너무 느릴 수 있다고 판단했습니다.
  - 1초 단위 즉시 평가/주문은 계산, REST refresh, 포지션 조회, 보호주문 처리 시간이 겹칠 수 있어 우선 3초 주기가 더 안전한 절충안으로 선택됐습니다.
  - Bitget position snapshot이 exchange-side TPSL 가격을 항상 `takeProfit`/`stopLoss` 필드로 반환하지 않아 차트에 진입선만 보이고 보호 가격선이 누락될 수 있습니다.
- Decision:
  - Dashboard Live monitor 기본 감시 주기는 3초로 둡니다.
  - 30초 주기는 더 이상 기본 live signal cadence가 아니며, 향후 15m WebSocket event-driven 평가로 전환하기 전까지 3초 monitor loop가 live 후보 평가 기준입니다.
  - 차트 포지션 라인은 position snapshot의 TP2/SL을 우선 사용하되, 값이 비어 있으면 최근 persistent live entry log의 `TP1`, `TP2`, `손절가` 값을 보강해 표시합니다.
- Consequences:
  - 진행 중 candle 신호 반응성이 개선되지만, Bitget REST refresh/포지션 조회 호출 빈도도 증가하므로 timeout/fallback 경로를 계속 유지해야 합니다.
  - 차트 TP1/TP2/SL 보강은 표시 목적이며, 실제 보호주문 상태의 진실 공급원은 Bitget TPSL 주문/포지션 조회와 live execution 로그입니다.

## 0025. Position Protection Display And Portfolio Scoring Enrichment

- Status: accepted
- Date: 2026-05-16
- Context:
  - Bitget position snapshot이 실제 TPSL 보호주문이 존재해도 `takeProfit`/`stopLoss` 필드를 비워 반환하는 사례가 확인됐습니다.
  - 이 경우 포지션 패널은 TP/SL을 `-`로 표시하고, portfolio arbitration은 기존 포지션의 남은 손익비를 `0:1`로 평가해 새 신호에 과도하게 교체될 수 있습니다.
  - Live log의 선정 로직 설명이 길면 중간에서 잘려 실제 교체 근거를 검토하기 어렵습니다.
- Decision:
  - Dashboard는 같은 symbol/side의 최근 persistent live entry log에서 `TP1`, `TP2`, `손절가`를 복구해 차트와 포지션 패널에 표시합니다.
  - Live monitor에 전달하는 open position도 동일한 보강값으로 enrich하여, Bitget position snapshot의 TP/SL 누락만으로 기존 포지션이 최저 점수가 되지 않게 합니다.
  - Forming candle에서 신호가 한번 accepted되면 기존 `(symbol,timeframe,strategy,openTime)` key로 중복 주문을 막고, no-signal 상태는 계속 재평가합니다.
  - 자동매매 로그 detail cell은 긴 `선정 로직` 값을 줄이지 않고 전체 표시합니다.
  - 신호 변경으로 기존 포지션을 정리하는 close log는 redacted order ID와 함께 `청산 직전 PnL`, `청산 판정`을 기록하고, 하단 누적 기록 패널은 해당 값을 승패/승률에 반영합니다.
- Consequences:
  - 보호주문이 있는데도 화면과 선정 로직에서 기존 포지션을 무보호/무가치로 보는 오판을 줄입니다.
  - close log의 승패는 실제 체결 후 정산된 realized PnL이 아니라 시장가 정리 직전 position snapshot 기준입니다. 정확한 확정 손익은 향후 order-history/position-history 연동으로 대체해야 합니다.
  - 주문 원문 응답과 raw order identifier는 계속 로그에 저장하지 않습니다.

## 0026. Hedge-Side Position Slots And Manual Refresh Reconciliation

- Status: accepted
- Date: 2026-05-16
- Context:
  - 사용자는 Bitget hedge mode에서 같은 symbol의 long/short를 동시에 보유할 수 있으므로 short 포지션이 있다고 long 신호까지 막지 않기를 원했습니다.
  - 반대로 이미 ETHUSDT short 포지션이 열려 있으면 새 ETHUSDT short 신호로 같은 방향을 재진입하거나 교체하지 않기를 원했습니다.
  - 사용자가 Bitget UI에서 TP/SL을 수동 수정한 뒤 앱 Refresh를 누르면 앱의 포지션/보호가격 표시와 선정 로직이 현재 거래소 상태를 따라가야 합니다.
- Decision:
  - Portfolio arbitration은 open position을 `symbol + side` 슬롯으로 취급합니다.
  - 같은 `symbol + side`가 이미 열려 있으면 해당 방향의 새 후보는 position close 전까지 hold 처리합니다.
  - 반대 방향은 별도 슬롯으로 취급하므로 hedge mode에서는 long/short 동시 보유 후보를 허용합니다.
  - Position Refresh는 Bitget `orders-plan-pending?planType=profit_loss&productType=USDT-FUTURES`를 함께 조회해 현재 pending TP/SL 주문을 우선 반영합니다.
  - pending TP/SL 조회가 성공하면 오래된 live entry log 값보다 거래소의 현재 보호주문 snapshot을 우선합니다. 조회가 실패하면 마지막 성공 snapshot 또는 live entry log로 표시를 보강합니다.
- Consequences:
  - 같은 방향 중복 진입/교체 churn을 줄이면서 반대 방향 hedge 진입은 허용됩니다.
  - 계정이 one-way mode이면 long/short 동시 보유는 거래소 정책상 의도대로 동작하지 않을 수 있으므로 live smoke에서 position mode 확인이 필요합니다.
  - 사용자가 수동으로 보호주문을 변경/삭제한 경우 Refresh 후 차트와 포지션 패널의 TP1/TP2/SL도 현재 거래소 pending plan 상태를 따릅니다.

## 0027. Prune Weak Symbol-Scoped Strategy Routes

- Status: accepted
- Date: 2026-05-21
- Context:
  - 현재 추천 라우팅을 `10x` leverage / `5%` per-trade account-risk 조건으로 재검증한 뒤, 사용자는 낮은 수익률 또는 높은 MDD 대비 효율이 약한 특정 조합을 제거하기로 했습니다.
  - 제거 대상은 전략 구현 전체가 아니라 `symbol × timeframe × strategy` route 단위입니다.
- Decision:
  - `BTCUSDT 15m X`를 추천 라우팅에서 제외합니다.
  - `BTCUSDT 12H Time-Series momentum`을 추천 라우팅에서 제외합니다.
  - `BTCUSDT 1D Donchian channel breakout`과 `BTCUSDT 1D VWMA100 touch trend`를 추천 라우팅에서 제외합니다.
  - `ETHUSDT 1D Donchian channel breakout`을 추천 라우팅에서 제외합니다.
  - 전략 구현체는 백테스트 재현성과 향후 명시적 재활성화를 위해 유지하고, active app route만 `blockedLiveRoutes`로 차단합니다.
- Consequences:
  - BTCUSDT 추천 route는 `15m X-Frequency`, `15m BTC 15m Phase Vacuum Reclaim`, `12H VWMA100 touch trend`, `12H Donchian channel breakout`만 남습니다.
  - ETHUSDT 추천 route는 `1H ETH 1H Momentum Burst`, `12H Time-Series momentum`만 남습니다.
  - Generic timeframe routing은 전략 카탈로그 성격으로 남아 있지만, Watchlist symbol이 주어지는 live/backtest 추천 경로에서는 symbol-scoped block list가 우선 적용됩니다.

## 0028. Further Prune Routed Strategy Portfolio

- Status: accepted
- Date: 2026-05-21
- Context:
  - 0027 적용 직후 사용자는 추가로 세 개의 active route를 더 제외하기로 했습니다.
  - 제거 대상은 계속 전략 구현 전체가 아니라 `symbol × timeframe × strategy` route 단위입니다.
- Decision:
  - `BTCUSDT 15m X-Frequency`를 추천 라우팅에서 제외합니다.
  - `BTCUSDT 12H Donchian channel breakout`을 추천 라우팅에서 제외합니다.
  - `ETHUSDT 12H Time-Series momentum`을 추천 라우팅에서 제외합니다.
  - 전략 구현체와 generic timeframe catalog는 유지하고, symbol-scoped active route만 `blockedLiveRoutes`로 차단합니다.
- Consequences:
  - BTCUSDT 추천 route는 `15m BTC 15m Phase Vacuum Reclaim`, `12H VWMA100 touch trend`만 남습니다.
  - ETHUSDT 추천 route는 `1H ETH 1H Momentum Burst`만 남습니다.
  - 재활성화가 필요하면 route 단위로 block list에서 되돌리고 같은 조건의 백테스트를 다시 실행해야 합니다.

## 0029. Route One Vacuum Pulse Strategy Per BTC/ETH Symbol

- Status: accepted
- Date: 2026-05-21
- Context:
  - 사용자는 `10x` leverage / `5%` per-trade account-risk 조건에서 최근 4년 15m candle 기준으로 BTCUSDT와 ETHUSDT 각각 하나의 공격형 전략을 원했습니다.
  - 후보 탐색은 기존 Phase Vacuum/Reclaim/Momentum 계열을 기준으로 하되, 라우팅은 BTC/ETH 각각 하나의 active route만 남기는 방향으로 정리했습니다.
- Decision:
  - `BTC 15m Vacuum Pulse`를 새 BTCUSDT 15m active route로 추가합니다.
  - `ETH 15m Vacuum Pulse`를 새 ETHUSDT 15m active route로 추가합니다.
  - `BTCUSDT 15m BTC Phase Vacuum Reclaim`, `BTCUSDT 12H VWMA100 touch trend`, `ETHUSDT 1H ETH 1H Momentum Burst`는 구현체를 유지하되 active app route에서는 제외합니다.
  - 두 Vacuum Pulse 전략의 default config는 `10x` leverage, `5%` per-trade account-risk, `100%` max margin, split TP/SL model 기준입니다.
- Consequences:
  - 현재 BTCUSDT/ETHUSDT active 추천 라우트는 각각 `15m Vacuum Pulse` 하나씩입니다.
  - 최신 로컬 4년 검증 결과는 `BTCUSDT 15m Vacuum Pulse`: `$100 -> $808.643489`, `+708.64%`, annualized `68.69%`, `156` trades, annual trades `39.03`, MDD `33.77%`, PF `1.59`입니다.
  - 최신 로컬 4년 검증 결과는 `ETHUSDT 15m Vacuum Pulse`: `$100 -> $637.452288`, `+537.45%`, annualized `58.95%`, `118` trades, annual trades `29.52`, MDD `22.00%`, PF `1.47`입니다.
  - 사용자의 이상 목표인 annual trades 약 `100`회와 annualized return `300%`에는 못 미치므로, 이 결과는 live-ready 보장이 아니라 현재 로컬 데이터와 수수료/TP-SL 모델에서의 최선 후보로 관리합니다.

## 0030. Reactivate Five Requested Symbol Routes

- Status: accepted
- Date: 2026-05-22
- Context:
  - 사용자는 Vacuum Pulse 2개만 남긴 상태가 아니라 기존 우수 후보 3개와 신규 Vacuum Pulse 2개를 함께 active route로 사용하길 원했습니다.
  - 요청한 active set은 `BTCUSDT 15m BTC 15m Phase Vacuum Reclaim`, `BTCUSDT 12H VWMA100 touch trend`, `ETHUSDT 1H ETH 1H Momentum Burst`, `BTCUSDT 15m BTC 15m Vacuum Pulse`, `ETHUSDT 15m ETH 15m Vacuum Pulse`입니다.
- Decision:
  - 위 다섯 개 `symbol × timeframe × strategy` 조합을 `symbolScopedLiveRoutes`에 명시합니다.
  - 기존 제외 대상 중 `BTCUSDT 15m Phase Vacuum Reclaim`, `BTCUSDT 12H VWMA100 touch trend`, `ETHUSDT 1H ETH 1H Momentum Burst`만 다시 활성화합니다.
  - `BTCUSDT 15m X`, `BTCUSDT 15m X-Frequency`, `BTCUSDT 12H Donchian`, `BTCUSDT 12H Time-Series`, `BTCUSDT 1D Donchian/VWMA`, `ETHUSDT 12H Time-Series`, `ETHUSDT 1D Donchian` 등 사용자가 제거한 나머지 route는 계속 제외합니다.
- Consequences:
  - 0030 적용 당시 active 추천 route는 BTCUSDT 3개, ETHUSDT 2개였습니다.
  - Live monitor는 동일 symbol/side 중복 포지션을 기존 portfolio policy로 걸러내며, 동시에 후보가 여러 개 나오면 reward/risk와 기대수익 기준으로 하나를 고릅니다.

## 0031. Strategy Holding-Period Exit Rationale

- Status: accepted
- Date: 2026-05-22
- Context:
  - 사용자는 전략별로 포지션을 며칠까지 보유할지 정하고, 그 기간 안에 결과가 나오지 않으면 자동 종료하는 조건을 원했습니다.
  - 단순 시간 만료가 아니라 해당 포지션을 왜 닫는지에 대한 근거도 로그와 백테스트 결과에 남아야 합니다.
  - 실거래 경로에서는 수동/외부 포지션까지 앱이 임의 청산하면 전략 근거와 사용자 의도를 증명할 수 없습니다.
- Decision:
  - `StrategyConfig.maximumHoldingCandles`를 추가해 전략별 최대 보유 candle 수를 설정합니다.
  - 적용 당시 active route 기본값은 `15m` 전략 `96`봉(약 24시간), `ETH 1H Momentum Burst` `72`봉(약 3일), `BTC 12H VWMA100` `14`봉(약 7일)이었습니다.
  - 백테스트는 TP2/SL이 최대 보유기간 안에 확정되지 않으면 해당 candle 종가에서 시간 종료를 만들고, 잔여 물량은 시장가/taker 수수료로 보수적으로 계산합니다.
  - Live monitor는 새 진입 평가 전에 app-created live entry log와 매칭되는 open position만 보유기간 만료 대상으로 봅니다.
  - 보유기간 종료 close log에는 `청산 근거`, `매매전략`, `시간봉`, `진입시각`, `최대 보유`, `경과 봉수`를 남깁니다.
- Consequences:
  - 자동매매는 신호가 오래 지연되는 포지션의 시간을 강제로 리셋할 수 있고, 종료 사유도 감사 로그에서 확인할 수 있습니다.
  - 보유기간 만료 청산이 발생한 평가 주기에는 새 진입을 만들지 않아 close와 entry가 같은 cycle에서 겹치지 않습니다.
  - 수동/외부 포지션은 자동 시간 종료 대상에서 제외됩니다. 앱이 만든 진입 로그가 없으면 전략/timeframe 근거가 없기 때문입니다.
  - TP1 체결 이후 남은 50%가 시간 종료되는 경우도 가능하며, 이 경우 백테스트 reason에는 TP1 이후 잔여 물량 종료라는 근거가 포함됩니다.

## 0032. Remove BTCUSDT 12H VWMA100 Active Route

- Status: accepted
- Date: 2026-05-23
- Context:
  - 사용자가 `BTC 12H VWMA100 터치 추세`를 앱 적용 전략에서 삭제하라고 요청했습니다.
  - 전략 구현체는 과거 백테스트 재현성과 명시적 재활성화 가능성을 위해 유지할 수 있습니다.
- Decision:
  - `BTCUSDT 12H VWMA100 touch trend`를 symbol-scoped active route에서 제거합니다.
  - 12H generic catalog에는 VWMA100이 남아 있으므로, `BTCUSDT 12H VWMA100`을 `blockedLiveRoutes`에도 명시해 앱/Live 추천 경로에서 다시 살아나지 않게 합니다.
- Consequences:
  - 현재 active 추천 route는 BTCUSDT 15m 2개, ETHUSDT 15m 1개, ETHUSDT 1H 1개입니다.
  - BTCUSDT 12H는 현재 추천 route가 없습니다.
  - VWMA100 터치 추세 구현체와 기본 `14`봉 최대 보유 설정은 registry에 남지만, BTCUSDT active Live route에는 적용되지 않습니다.

## 0033. Cap Live Entry Size By Available Balance

- Status: accepted
- Date: 2026-05-25
- Context:
  - Live monitor가 신호를 만들었지만 Bitget이 `40762 The order amount exceeds the balance`로 주문을 거절했습니다.
  - 기존 리스크 정책은 `10x` leverage와 `5%` account-risk를 적용해 포지션 투입비율을 계산했지만, 실제 주문 수량 산출은 USDT `accountEquity`만 기준으로 삼았습니다.
  - Bitget 주문 가능 금액은 열린 포지션, 예약 주문, 수수료 여유분 때문에 `accountEquity`보다 작은 `available` 기준으로 제한될 수 있습니다.
- Decision:
  - Dashboard Live monitor는 USDT `accountEquity`와 함께 `available`을 Live executor에 전달합니다.
  - Live order sizing은 기존 risk-sized planned margin을 유지하되, 주문 직전 사용 증거금을 `available × 95%` 이하로 한 번 더 제한합니다.
  - 제한 후 주문 수량이 Bitget 최소 주문 조건보다 작으면 live order size too small로 차단하고 주문을 제출하지 않습니다.
- Consequences:
  - `10x`와 `5%` 리스크 정책은 계속 적용됩니다. 다만 실제 available balance가 부족하면 주문 크기가 더 작아져 계좌 손실위험도 5%보다 낮아질 수 있습니다.
  - 신규 주문이 현재 운용 가능한 금액을 초과해 거래소에서 거절될 가능성을 줄입니다.
  - available balance가 너무 낮으면 신호가 있어도 주문이 차단될 수 있으며, 이는 잔고 초과 주문보다 안전한 실패입니다.

## 0034. Restrict Runtime Market Data To 15m Closed Candles

- Status: accepted
- Date: 2026-05-29
- Context:
  - 사용자는 최근 검증에서 가장 유효했던 전략들이 15m 중심이고, 포지션도 하루 이상 길게 유지하지 않는 방향을 선호한다고 정리했습니다.
  - 기존 런타임은 Watchlist의 `15m`, `1H`, `4H`, `12H`, `1D`를 REST로 각각 받아오고, Live monitor는 forming candle까지 후보 평가할 수 있어 closed-candle 백테스트와 live 진입 기준 사이에 간극이 있었습니다.
  - 사용자는 앱 클라이언트를 항상 켜두지 않고도 자동매매가 지속되는 구조를 원하므로, UI 선택 상태와 실행 엔진 책임을 더 명확히 나눌 필요가 있습니다.
- Decision:
  - 이 결정은 0023의 Live forming candle evaluation을 Dashboard/Live runtime에서 supersede합니다.
  - Dashboard/Live runtime의 candle REST backfill, public WebSocket candle subscription, Live monitor 평가 범위를 `15m`로 제한합니다.
  - Live entry 평가는 closed 15m candle만 사용합니다. forming candle은 chart/cache에 반영될 수 있지만 strategy entry 후보에는 넣지 않습니다.
  - `ETHUSDT 1H Momentum Burst`는 구현체와 연구 기록은 유지하되 Dashboard/Live active route에서 제거합니다.
  - `CandleTimeframe`의 higher timeframe cases는 과거 데이터/백테스트 재현과 명시적 연구용으로 남기고, 앱 런타임 범위는 `dashboardCases`, `marketDataSyncCases`, `liveTradingCases` 상수로 제한합니다.
  - 백그라운드 상시 실행은 이번 변경에 포함하지 않고 다음 구조 변경으로 분리합니다. 다음 단계는 UI 앱이 설정/상태 조회/Start-Stop만 담당하고, 별도 runner 또는 LaunchAgent가 REST/WS, strategy, live execution을 소유하는 형태입니다.
- Consequences:
  - 앱 시작 시 BTCUSDT/ETHUSDT의 15m history만 동기화하므로 REST 요청량과 local bootstrap 시간이 줄어듭니다.
  - Live monitor는 UI에서 보이는 차트 상태가 아니라 Watchlist 15m closed candle 상태를 기준으로 판단합니다.
  - closed-candle 백테스트와 live 판단 기준이 같아져, 진행 중 candle 무빙을 이용한 조기 진입 간극을 제거합니다.
  - higher timeframe 전략은 registry와 generic research catalog에는 남을 수 있지만, symbol-scoped Dashboard/Live 추천 경로에는 포함되지 않습니다.

## 0035. Introduce Server Paper Runner Before Remote Live Execution

- Status: accepted
- Date: 2026-05-29
- Context:
  - 사용자는 Mac을 꺼도 자동매매가 계속 실행되는 구조를 원했고, AWS Lightsail Ubuntu 서버를 준비했습니다.
  - 기존 macOS 앱은 UI, Keychain credential, local candle storage, Live monitor를 모두 한 프로세스 안에 갖고 있어 Ubuntu 서버에 그대로 올릴 수 없습니다.
  - 실거래 서버 전환은 credential 저장, 주문, 보호주문, fail-closed 책임을 옮기는 고위험 변경이므로 먼저 public market data와 paper signal만 검증해야 합니다.
- Decision:
  - 서버 paper runner는 Python 컨테이너로 운영합니다. Swift 런타임/권한 의존을 제거해 Lightsail Ubuntu에서 우선 안정적으로 실행되게 합니다.
  - runner는 현재 활성 live route인 BTC 15m Phase Vacuum Reclaim, BTC 15m Vacuum Pulse, ETH 15m Vacuum Pulse 조건을 Python으로 이식하고, Bitget public REST `15m` candle만 받아 file-based JSON 저장소에 저장합니다.
  - runner는 closed 15m candle별 `symbol × timeframe × strategy × openTime` key를 저장해 같은 candle의 paper signal 중복 평가를 막습니다.
  - runner는 `paper-runner-status.json`, `paper-runner-evaluations.jsonl`, `trade-event-logs.jsonl`에 상태와 paper signal을 남깁니다.
  - runner는 서버 로컬 바인딩용 HTTP API(`/health`, `/status`, `/logs`, `/candles`, `/control`)를 제공하고, Docker Compose는 host `127.0.0.1`에만 포트를 노출합니다.
  - 이 단계는 private Bitget API, credential 저장, live order, protection order를 포함하지 않습니다.
- Consequences:
  - Lightsail 서버에서 Docker Compose로 paper runner를 먼저 장시간 검증할 수 있습니다.
  - macOS 앱을 서버 클라이언트로 바꾸기 전에 서버 status/log contract를 확인할 수 있습니다.
  - 실거래 서버 전환은 별도 decision으로 분리하고, credential secret storage, API auth, duplicate runner lock, position reconciliation, exchange-side protection 검증을 요구합니다.

## 0036. Split Shared Market Data From User Paper Bot State

- Status: accepted
- Date: 2026-05-29
- Context:
  - 사용자는 여러 사용자가 같은 서버를 쓰더라도 Bitget public candle 데이터는 하나로 받고, 사용자별 자동매매 ON/OFF와 거래 기록은 분리되어야 한다고 정리했습니다.
  - Bitget public OHLCV 조회는 API key가 필요 없지만, 각 사용자의 잔고/포지션/주문은 나중에 사용자별 private credential 경계가 필요합니다.
  - 서버 API를 외부에 열기 전 최소 인증 경계가 필요하지만, 현재 운영은 SSH tunnel 또는 server-local API를 우선합니다.
- Decision:
  - 서버 market data store는 `candles-{symbol}-15m.json` 공용 파일을 계속 사용합니다.
  - paper bot의 `control`, `status`, `evaluations`, `trade-event-logs`는 `users/{userID}/` 아래 사용자별 파일로 분리합니다.
  - API는 `/users/me/status`, `/users/me/logs`, `/users/me/candles`, `/users/me/control`을 우선 route로 사용하고, 기존 `/status`, `/logs`, `/candles`, `/control`은 default/authenticated user 호환 route로 유지합니다.
  - bearer token auth는 `auth-users.json` 파일이 있거나 `BUCKS_COPY_REQUIRE_AUTH=true`일 때 활성화합니다. token은 로그/문서/코드에 저장하지 않고 서버 로컬 secret 파일로만 둡니다.
  - macOS 앱은 `BUCKS_COPY_SERVER_API_TOKEN`이 있거나 Keychain에 저장된 server runner token이 있으면 bearer token을 붙여 `/users/me/*` route를 호출합니다.
  - server runner endpoint/token은 `ServerRunnerConfigurationStore` 경계 뒤에 두고, macOS 구현체는 Keychain-facing Data adapter가 소유합니다.
  - 이번 결정은 paper-only 상태 분리까지이며, Bitget private credential 저장, private WebSocket, live order execution은 포함하지 않습니다.
- Consequences:
  - public candle 수집 비용은 사용자 수와 거의 무관하게 유지됩니다.
  - 사용자별 paper 평가와 로그는 독립적으로 쌓이며, 한 사용자의 ON/OFF가 다른 사용자에게 영향을 주지 않습니다.
  - 서버를 공용 서비스로 확장할 때 user-specific strategy config, credential storage, account/position polling, live protection order state를 별도 migration으로 추가해야 합니다.

## 0037. Add HTTPS Edge For Server Paper API

- Status: accepted
- Date: 2026-05-29
- Context:
  - SSH tunnel은 개인 검증에는 안전하지만, 사용자가 앱만 열어 서버 상태를 확인하고 ON/OFF를 제어하려는 흐름에는 부담이 큽니다.
  - 서버 API를 인터넷에 직접 열려면 HTTPS와 bearer token 인증이 필수이며, raw `8787` HTTP 포트를 외부에 공개하면 안 됩니다.
  - Caddy는 Docker Compose에서 자동 TLS 인증서 발급/갱신을 처리할 수 있어 Lightsail 단일 서버 운영에 적합합니다.
- Decision:
  - `paper-runner` 컨테이너는 기존처럼 내부 HTTP API를 유지하고, host `127.0.0.1:8787` 바인딩은 server-local 확인용으로만 둡니다.
  - public mode는 별도 compose override `Server/docker-compose.https.yml`로 Caddy reverse proxy를 추가합니다.
  - Caddy는 `80/443`만 외부에 열고 `/health`, `/users/me/*`만 `paper-runner:8787`로 proxy합니다. legacy `/status`, `/control`, `/logs`, `/candles`는 public edge에서 노출하지 않습니다.
  - HTTPS public mode에서는 compose override가 `BUCKS_COPY_REQUIRE_AUTH=true`를 강제합니다. `auth-users.json`이 없어도 runner는 시작할 수 있으며, token이 필요한 `/users/me/*`는 로그인 또는 auth file 생성 전 401로 실패합니다.
  - TLS 인증서는 `BUCKS_COPY_SERVER_DOMAIN`으로 받은 실제 DNS 이름을 기준으로 Caddy가 관리합니다.
- Consequences:
  - macOS 앱은 SSH tunnel 없이 `https://<domain>` endpoint와 Keychain에 저장된 bearer token으로 paper runner 상태를 조회/제어할 수 있습니다.
  - 도메인 DNS, Lightsail firewall `80/443`, Caddy data/config volume이 추가 운영 전제입니다.
  - 이 단계도 paper-only API edge이며 Bitget private credential, private WebSocket, live order execution은 포함하지 않습니다.

## 0038. Replace Manual Server Token Entry With Bitget Server Login

- Status: accepted
- Date: 2026-05-29
- Context:
  - 수동 bearer token 입력은 단일 운영자 검증에는 충분하지만, 여러 사용자가 앱에서 자신의 Bitget API key/secret/passphrase로 접속하는 흐름에는 맞지 않습니다.
  - 사용자는 기존 API credential 입력 자체를 로그인으로 사용하고, Bitget 조회가 성공하면 앱 session token을 내려받는 구조를 원했습니다.
  - 다만 server-side live trading은 아직 구현 전이므로 Bitget secret/passphrase를 서버에 영구 저장하면 보안 범위가 과도하게 커집니다.
- Decision:
  - public Caddy edge는 `/auth/bitget/login`을 추가 proxy합니다.
  - server paper runner는 login 요청의 Bitget credential로 `USDT-FUTURES` account read를 1회 수행해 유효성을 검증합니다.
  - 검증 성공 시 API key hash 기반 userID와 bearer token을 `auth-users.json`에 저장하고, 앱에는 server session token과 redacted identifier만 반환합니다.
  - Bitget API key, secret, passphrase는 이번 paper runner 단계에서 저장하지 않습니다.
  - macOS 앱은 API credential 입력 후 server login을 수행하고, Bitget secret/passphrase 대신 server endpoint/token만 Keychain에 저장합니다.
  - 기존 local credential path는 테스트와 아직 로컬 live executor가 필요한 개발 경로를 위해 fallback으로 남기되, 기본 앱 endpoint는 `https://api.buckscopy.com`입니다.
- Consequences:
  - 사용자는 수동 token 복사 없이 Bitget API credential로 앱 session을 만들 수 있습니다.
  - 사용자별 paper state/control/log는 발급된 userID로 분리됩니다.
  - 서버가 Mac 클라이언트 없이 실거래 주문을 실행하려면 encrypted credential storage, session revocation, account/position polling, exchange-side protection order flow를 별도 decision으로 추가해야 합니다.

## 0039. Server Read-Only Private Snapshots Use Memory-Only Credential

- Status: accepted
- Date: 2026-05-29
- Context:
  - Bitget server login 후 앱이 잔고/포지션을 계속 로컬 Keychain credential로 조회하면, 서버 로그인과 UI 상태 확인 흐름이 분리되어 사용자가 혼란스럽습니다.
  - 사용자는 앱을 상태 확인/ON-OFF 클라이언트로 쓰고, 서버가 사용자별 상태를 읽어오는 방향을 원했습니다.
  - 아직 server-side live trading consent, encrypted credential storage, protection order state machine은 구현 전이므로 서버에 Bitget credential을 영구 저장하면 보안 범위가 과도합니다.
- Decision:
  - `/auth/bitget/login` 성공 후 Bitget API key, secret, passphrase는 paper runner process memory에만 보관합니다.
  - 서버는 authenticated user session에 대해 `/users/me/account`, `/users/me/positions` read-only endpoint를 제공합니다.
  - account/position endpoint는 Bitget raw private response 전체가 아니라 UI에 필요한 normalized snapshot만 반환합니다.
  - 컨테이너 재시작으로 memory credential이 사라지면 private snapshot endpoint는 `409`로 실패하고, macOS 앱은 Bitget login이 다시 필요하다고 표시합니다.
  - 이 단계는 private account/position read-only까지이며 private WebSocket, live order, protection order, persistent credential storage는 포함하지 않습니다.
- Consequences:
  - 앱은 서버 로그인 이후 계정/포지션 표시를 같은 server session 경계로 조회할 수 있습니다.
  - 서버 재시작 후에는 session token이 남아도 private snapshot 조회를 위해 사용자가 다시 Bitget login을 해야 합니다.
  - 실거래 서버 전환 전에는 credential encryption/rotation/revocation, account/position polling policy, order consent, exchange-side TP/SL protection, fail-closed close path를 별도 결정으로 추가해야 합니다.

## 0040. Server Session Logout Revokes Token And Memory Credential

- Status: accepted
- Date: 2026-05-29
- Context:
  - 앱 Disconnect가 로컬 Keychain state만 지우면 서버의 bearer token과 process-memory Bitget credential이 컨테이너 종료 전까지 남을 수 있습니다.
  - 실거래 서버 전환 전에도 사용자가 명시적으로 접속을 끊으면 서버 session과 private read 권한이 같이 사라져야 합니다.
  - user-scoped paper runner data는 credential secret이 아니므로 로그아웃 때 삭제하면 운영/감사 흐름이 불필요하게 깨집니다.
- Decision:
  - 서버는 authenticated user 전용 `DELETE /users/me/session` endpoint를 제공합니다.
  - endpoint는 해당 user의 bearer token을 `auth-users.json`에서 제거하고, process-memory Bitget credential을 제거합니다.
  - user paper state/control/log/candle data는 삭제하지 않습니다.
  - macOS 앱의 Disconnect는 서버 revoke를 요청하고, 네트워크 실패가 있어도 로컬 Keychain/session state는 정리합니다.
- Consequences:
  - 사용자는 앱에서 명시적으로 서버 session을 폐기할 수 있습니다.
  - revoke 이후 기존 bearer token으로 `/users/me/*` 요청을 보내면 401로 실패해야 합니다.
  - server-side live execution 전에는 여전히 encrypted credential storage, account/position polling policy, protection order state machine이 별도 필요합니다.
