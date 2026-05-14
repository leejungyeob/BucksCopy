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
  - 자동매매/백테스트 공통 risk policy는 최대 레버리지 `10x`, 최소 손익비 `2:1`, 레버리지 반영 손절 위험 `< 30%`를 강제합니다.
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
  - risk policy는 최소 `2:1` 손익비, 레버리지 반영 손절 위험 `< 30%`, 익절 기대 수익 `> 진입 taker + 익절 maker 수수료`를 모두 만족해야 통과합니다.
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
