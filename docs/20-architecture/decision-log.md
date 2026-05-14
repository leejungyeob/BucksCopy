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
