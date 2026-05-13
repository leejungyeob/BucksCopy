# Test Strategy

## 한글 요약

- 테스트는 변경 위험에 맞는 가장 작은 검증 세트를 고릅니다.
- 자동매매 도메인은 happy path보다 실패/경계/재현 가능성을 더 중요하게 봅니다.
- 코드 테스트가 아직 없더라도 acceptance scenario는 반드시 남깁니다.

## 작업 유형별 기본 기대치

| 작업 유형 | 기본 기대치 |
| --- | --- |
| 문서/하네스 변경 | agent config/routing/trace checks |
| macOS UI 변경 | 수동 스모크 + 상태/입력 validation |
| Bitget REST/WS 변경 | DTO mapping, signature boundary, reconnect/backoff, error mapping |
| dashboard 변경 | connect-only credential flow, auto-connect, timeframe switching, read-only position table, Paper start/stop, log persistence |
| symbol catalog / Watchlist 변경 | `symbolStatus=normal`, `supportMarginCoins` contains `USDT`, Watchlist-only subscription |
| local market history 변경 | upsert idempotency, startup gap fill, closed-candle-only read, no secret persistence |
| credential storage 변경 | Security checklist + Keychain delete/read/write failure cases |
| candle builder 변경 | 15m/1H/4H/12H/1D bucket, boundary timestamp, missing/out-of-order input |
| strategy 변경 | built-in registry coverage, signal generation, no duplicate order intent, closed-candle 기준 |
| backtest 변경 | manual trigger, background execution, symbol/timeframe/strategy config, Korean result summary, risk-blocked signal count |
| paper execution 변경 | accepted/rejected/risk-blocked/fill simulation |
| live execution policy 변경 | 별도 decision log + Security + TDD Guide 필수 |

## Acceptance Scenario 작성 규칙

- 사용자가 무엇을 시작하는가
- 정상 완료 기준이 무엇인가
- 실패 시 상태가 어떻게 바뀌는가
- 회귀가 가장 무서운 경로가 무엇인가

예시:

- API credential 입력 -> Connect -> Keychain 저장 -> 연결 테스트 성공 -> credential 원문 로그 없음
- 앱 재시작 -> 저장된 credential 자동 연결 -> 계정 요약 UI 표시
- Dashboard 시작 -> 로컬 candle seed/load -> 단일 SwiftUI Canvas price chart 표시 -> timeframe 변경 시 candle series 교체
- Chart 조작 -> 확대/축소와 좌우/상하 drag pan이 candle viewport와 price range를 연속적으로 바꿈
- USDT-M Futures catalog 로드 -> `normal` + `USDT` margin 중 BTCUSDT/ETHUSDT만 앱 catalog와 Watchlist에 보관
- Watchlist 선택 -> 선택된 심볼만 WebSocket 구독 -> 선택 해제된 심볼은 strategy 대상 제외
- REST candle backfill 성공 -> 같은 심볼/타임프레임 WebSocket candle 구독 시작 -> push candle이 SQLite와 chart state에 upsert
- Bitget position fixture -> read-only `PositionSnapshot` 매핑 -> live order API 호출 없음
- WebSocket disconnect -> ping timeout 감지 -> backoff reconnect -> 중복 subscribe 없음
- Watchlist가 단일 연결 권장선인 50채널을 초과 -> validation 실패 또는 명시적 연결 분리
- 1분 입력 candle stream -> 15m candle close -> strategy가 closed candle만 소비
- 로컬 DB에 1시간 전 closed candle까지 있음 -> 앱 시작 -> gap만 REST로 보충 -> 중복 없이 upsert
- Bitget candle API 조회 가능 기간보다 오래된 로컬 candle 있음 -> 재시작 후 삭제하지 않고 strategy warmup에 사용
- strategy 매수 signal -> paper order intent 생성 -> risk policy 통과 -> simulated fill 기록
- 백테스트 설정 -> BTCUSDT/ETHUSDT 중 선택 -> 시간봉 선택 -> 전략 선택 -> 수동 실행 -> UI는 즉시 running 상태가 되고 계산 완료 후 승률/손익비/차단 신호가 한국어로 표시
- 백테스트 실행 중 전략/코인/시간봉 변경 -> 기존 작업 취소 -> 이전 결과가 새 설정에 섞이지 않음
- 손익비 2:1 미만 또는 레버리지 반영 손절 위험 30% 이상 signal -> paper/backtest 모두 risk-blocked로 처리
- 레버리지 stepper -> contract max가 10보다 크더라도 자동매매 설정은 10x 이하로 제한
- NoopStrategy 선택 -> Paper start -> signal 없음 -> bot event log 저장

## 최소 검증 원칙

1. Domain rule은 네트워크 없이 deterministic 테스트를 우선합니다.
2. Data mapping은 fixture 기반으로 성공/실패 응답을 모두 봅니다.
3. Data orchestration은 clock, HTTP, WebSocket, local store를 주입 가능하게 둡니다.
4. UI는 credential 원문 노출과 live trading enable 상태를 스모크합니다.
5. Watchlist에 없는 심볼은 subscription, strategy, paper order 단계에서 모두 제외되는지 확인합니다.
6. Local market history에는 API key, secret, passphrase, raw private response가 저장되지 않는지 확인합니다.
7. Backtest runner는 앱 시작 시 자동으로 실행되지 않고, 수동 실행 경로에서만 대량 candle을 읽는지 확인합니다.
