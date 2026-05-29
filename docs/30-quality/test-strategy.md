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
| dashboard 변경 | connect-only credential flow, auto-connect, 15m timeframe enforcement, position table, Live start/stop consent gate, log persistence |
| symbol catalog / Watchlist 변경 | `symbolStatus=normal`, `supportMarginCoins` contains `USDT`, Watchlist-only subscription |
| local market history 변경 | upsert idempotency, startup gap fill, closed-candle-only read, no secret persistence |
| server paper runner 변경 | Python runner syntax check, local-only or bearer-auth status/control API, 15m public candle fetch, shared market candle persistence, user-scoped status/log/control/evaluation persistence, duplicate paper evaluation guard, no private Bitget/order path |
| credential storage 변경 | Security checklist + Keychain delete/read/write failure cases |
| candle builder 변경 | 15m/1H/4H/12H/1D bucket, boundary timestamp, missing/out-of-order input |
| strategy 변경 | built-in registry coverage, signal generation, no duplicate order intent, backtest/live closed-candle 기준 |
| backtest/strategy validation 변경 | engine-level deterministic tests, local-candle validation runner, risk-blocked signal count, primary result consistency |
| live execution 변경 | decision log + Security + TDD Guide, DTO mapping, fill confirmation, position verification, protection retry, fail-closed close/skip |

## Acceptance Scenario 작성 규칙

- 사용자가 무엇을 시작하는가
- 정상 완료 기준이 무엇인가
- 실패 시 상태가 어떻게 바뀌는가
- 회귀가 가장 무서운 경로가 무엇인가

예시:

- API credential 입력 -> Connect -> Keychain 저장 -> 연결 테스트 성공 -> credential 원문 로그 없음
- 앱 재시작 -> 저장된 credential 자동 연결 -> 계정 요약 UI 표시
- Dashboard 시작 -> 로컬 15m candle seed/load -> 단일 SwiftUI Canvas price chart 표시 -> higher timeframe 선택 시 상태 변경 없음
- Chart 조작 -> 확대/축소와 좌우/상하 drag pan이 candle viewport와 price range를 연속적으로 바꿈
- USDT-M Futures catalog 로드 -> `normal` + `USDT` margin 중 BTCUSDT/ETHUSDT만 앱 catalog와 Watchlist에 보관
- Watchlist 선택 -> 선택된 심볼만 WebSocket 구독 -> 선택 해제된 심볼은 strategy 대상 제외
- REST 15m candle backfill 성공 -> 같은 심볼의 15m WebSocket candle 구독 시작 -> push candle이 SQLite와 chart state에 upsert
- Dashboard 시작 -> BTCUSDT/ETHUSDT Watchlist의 `15m` 저장 상태 확인 -> 미완료 라우트만 REST backfill -> 완료 라우트는 재다운로드 없이 건너뜀
- Bitget position fixture -> read-only `PositionSnapshot` 매핑 -> live order API 호출 없음
- WebSocket disconnect -> ping timeout 감지 -> backoff reconnect -> 중복 subscribe 없음
- Watchlist가 단일 연결 권장선인 50채널을 초과 -> validation 실패 또는 명시적 연결 분리
- 1분 입력 candle stream -> 15m candle close -> backtest/validation strategy가 closed candle만 소비
- 로컬 DB에 1시간 전 closed candle까지 있음 -> 앱 시작 -> gap만 REST로 보충 -> 중복 없이 upsert
- Bitget candle API 조회 가능 기간보다 오래된 로컬 candle 있음 -> 재시작 후 삭제하지 않고 strategy warmup에 사용
- strategy 매수 signal -> live candidate 생성 -> risk policy 통과 -> 명시 동의 상태에서 market entry와 보호주문 기록
- fill receipt 수신 -> position snapshot에 같은 symbol/side open position 없음 -> 보호주문과 fail-closed 청산 모두 생략하고 warning log 기록
- 백테스트 시작금액 설정 -> 첫 거래 수익률을 시작잔고에 반영 -> 다음 거래는 갱신된 잔고 기준으로 복리 계산 -> 최종잔고와 순손익 표시
- 백테스트 중 포지션이 여러 candle 뒤에 청산 -> 그 사이 candle은 신규 진입 평가는 건너뛰되 이후 지표 history에는 포함
- 백테스트 실행 중 전략/코인/시간봉 변경 -> 기존 작업 취소 -> 이전 결과가 새 설정에 섞이지 않음
- 다중 전략 포트폴리오 설정 -> 한 시간봉에 여러 전략 활성화 -> closed candle마다 해당 symbol/timeframe의 활성 전략을 모두 평가
- Live monitor 시작 -> Watchlist의 `15m` 최신 completed candle만 평가 -> 추천 전략 신호가 있으면 Live 로그에 15m가 기록
- Live monitor 실행 -> 기본 3초 주기로 REST/local 최신 completed 15m candle을 재확인 -> 진행 중 candle 신호는 후보로 올리지 않음
- Live monitor 시작 -> 현재 최신 completed 15m candle key를 먼저 priming -> Start Live 전에 이미 닫힌 candle 신호는 실주문으로 쓰지 않음 -> 다음 completed 15m candle 신호부터 주문 후보 허용
- Server paper runner 시작 -> Bitget public REST에서 Watchlist `15m` candle만 가져옴 -> file-based candle store에 upsert -> closed candle만 전략 평가에 사용
- Server paper runner 반복 실행 -> 같은 `symbol/timeframe/strategy/candle openTime`은 `paper-runner-evaluations.jsonl`로 중복 평가하지 않음
- Server paper runner signal 발생 -> `trade-event-logs.jsonl`에 `PAPER` signal을 남기고 live order API는 호출하지 않음
- Server paper runner heartbeat -> `paper-runner-status.json`에 최신 상태를 저장하고 credential, signature, raw private response를 저장하지 않음
- Server paper runner multi-user -> `candles-{symbol}-15m.json`은 공용으로 1번 저장 -> 각 사용자의 `users/{userID}/paper-runner-control.json` ON/OFF와 logs/evaluations/status는 서로 분리됨
- Server paper runner auth enabled -> bearer token 없는 `/users/me/status`는 401 -> 올바른 token은 자신의 user-scoped status만 조회 -> token 원문은 로그에 남지 않음
- Live 진입 로그에 TP1/TP2/손절가가 기록되고 Bitget position snapshot의 TP/SL이 비어 있음 -> 차트와 포지션 패널은 같은 symbol/side의 최근 live entry log 값으로 ENTRY/TP1/TP2/SL을 함께 표시
- Live 진입 로그에 TP1/TP2/손절가가 있고 position snapshot의 TP/SL이 비어 있음 -> Live monitor portfolio arbitration은 log 보강값으로 기존 포지션의 남은 손익비를 계산
- Live monitor 시작 -> 현재 USDT account equity를 자동매매 시작 기록으로 영구 저장 -> 하단 자동매매 기록 패널이 새 시작마다 리셋되지 않고 누적 시드, 현재 equity, 추정 순수익, 누적 기간, 진입/청산 로그 수, 확정 승패/승률, 리스크 이벤트를 표시
- 같은 `symbol/timeframe/strategy/candle openTime` signal을 반복 평가 -> live order가 중복 생성되지 않음
- forming candle 수신 -> SQLite/chart에는 반영 가능하지만 Live monitor는 해당 candle이 closed 상태가 될 때까지 entry 평가에서 제외
- 같은 실행 주기에 여러 추천 전략 신호가 발생 -> 손익비가 가장 높은 후보 1개만 live order로 기록
- 손익비가 같은 여러 신호가 발생 -> 계좌 기준 기대순익 금액이 가장 큰 후보를 선택
- ETHUSDT short 포지션 보유 중 ETHUSDT short 새 신호 발생 -> 같은 symbol/side 슬롯이 점유되어 신규 진입/변경 없이 보류
- ETHUSDT short 포지션 보유 중 ETHUSDT long 새 신호 발생 -> hedge mode 기준 반대 방향 슬롯이 비어 있으므로 후보로 허용
- app-created live entry log와 매칭되는 포지션이 전략별 최대 보유기간을 초과 -> Live monitor가 신규 진입 평가 전에 close-positions 요청 -> close log에 `청산 근거`와 경과 봉수 기록
- 새 신호로 기존 포지션을 시장가 정리 -> close log에 청산 직전 PnL과 승/패 판정 기록 -> 하단 자동매매 기록의 승패/승률에 반영
- 진행 중 포지션의 남은 손익비/기대수익이 새 신호 이상 -> 새 신호를 보류하고 기존 포지션 유지 decision 기록
- higher timeframe 선택 시도 -> Dashboard/Backtest selector가 15m 상태를 유지하고 Live monitor 범위도 15m로 유지
- 전략 × 시간봉 백테스트 -> 조합별 승률/순손익/거래 수/최대 낙폭 표시 -> 포트폴리오 합산 성과와 분리해 비교 가능
- 동일 symbol/timeframe에서 여러 전략이 동시에 signal 생성 -> 중복 진입, 같은 방향 추가 진입, 반대 신호 처리 정책이 deterministic하게 적용
- 손익비 2:1 미만, 레버리지 10x 초과, 또는 익절 기대 수익이 진입 taker + 익절 maker 수수료 이하인 signal -> live/backtest 모두 risk-blocked로 처리
- 최대 보유기간이 설정된 백테스트 거래가 TP2/SL 미도달 상태로 기간 만료 -> candle 종가 시간 종료, taker 수수료, Korean reason 기록
- 손절폭이 큰 signal -> 차단하지 않고 `손절폭 × 레버리지 × 투입비율 <= 1회 최대 손실률`이 되도록 포지션 투입비율을 축소
- Live order sizing -> risk-sized planned margin이 USDT available balance 95%보다 크면 available buffer 기준으로 주문 수량 축소
- 1회 최대 손실률 설정 -> 기본 5%, UI 최대 15%로 제한
- Backtest risk-blocked signal -> 차단 사유를 손절 위험, 손익비, 수수료, 레버리지 제한 등으로 집계해 결과 화면에 표시
- TP 2분할 -> 진입가와 최종 목표가의 중간값에서 50% 익절 -> 남은 50%는 최종 목표가 또는 profit-lock stop 중 먼저 닿는 가격에 청산
- TP1 이후 profit-lock stop -> stop-loss를 진입가에서 목표가 방향 25% 지점으로 이동 -> 목표가를 못 가고 되돌아와도 남은 물량이 익절로 끝남
- 수수료 모델 -> entry taker, take-profit maker, stop-loss taker를 결과별로 계산
- 진입 체결 후 보호 주문 설치 -> TP1/TP2 limit 보호 주문과 SL market 보호 주문이 모두 거래소에 등록되어야 protected 상태로 처리
- live TP1 체결 후 -> 기존 SL을 취소/재등록해 profit-lock stop으로 이동하는 상태 전이가 필요함
- TP/SL 보호 주문 등록 실패 -> 실패한 주문별 최소 5회 재시도 -> 재시도 소진 시 protection-failed 상태와 fail-closed 경로 확인
- 보호주문 실패 후 fail-closed 직전 position snapshot에 닫을 포지션 없음 -> `close-positions` 미호출 및 청산 생략 log 확인
- 앱 재시작 -> 현재 포지션과 거래소-side TP/SL 보호 주문을 조회 -> 누락된 보호 주문 감지
- 레버리지 stepper -> contract max가 10보다 크더라도 자동매매 설정은 10x 이하로 제한
- 선택한 전략 조건 미충족 -> Live start -> signal 없음 -> bot event log 미저장

## 최소 검증 원칙

1. Domain rule은 네트워크 없이 deterministic 테스트를 우선합니다.
2. Data mapping은 fixture 기반으로 성공/실패 응답을 모두 봅니다.
3. Data orchestration은 clock, HTTP, WebSocket, local store를 주입 가능하게 둡니다.
4. UI는 credential 원문 노출과 live trading enable 상태를 스모크합니다.
5. Watchlist에 없는 심볼은 subscription, strategy, live order 단계에서 모두 제외되는지 확인합니다.
6. Local market history에는 API key, secret, passphrase, raw private response가 저장되지 않는지 확인합니다.
7. Backtest runner는 앱 시작 시 자동으로 실행되지 않고, 수동 실행 경로에서만 대량 candle을 읽는지 확인합니다.
8. Live monitor는 UI 상태와 독립적으로 Watchlist 15m closed candle만 평가하되, 같은 candle openTime에서 중복 주문을 만들지 않는지 확인합니다.
