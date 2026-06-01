# Security Checklist

## 한글 요약

- Bitget API key, secret, passphrase, order/account data는 고위험 민감정보입니다.
- v1은 명시 동의 기반 Live trading이며 live order는 연결된 credential, 서버 live 동의, risk policy, portfolio arbitration을 통과해야만 호출됩니다.
- Security 역할은 auth, token, encrypted credential storage, logging, REST/WebSocket, order boundary를 중점 검토합니다.

## 기본 원칙

1. Secret은 최소 저장, 최소 노출합니다.
2. credential은 서버 메모리 또는 AES-256-GCM encrypted user credential 파일에만 둡니다.
3. 로그는 원인 파악에 필요한 최소 metadata만 남깁니다.
4. 외부 응답은 DTO 경계에서 검증/매핑한 뒤 사용합니다.
5. live execution은 명시 동의, 보호주문, fail-closed 경로 없이는 활성화하지 않습니다.

## 체크리스트

### Secrets / Config

- API key, secret, passphrase가 코드/문서/fixture/log에 하드코딩되지 않았는가
- `.env`, local config, sample 값이 실제 credential처럼 보이지 않는가
- 서명 payload, signature, raw header가 로그에 남지 않는가
- server paper runner는 `/auth/bitget/login` 이후 Bitget API key/secret/passphrase를 process memory에 올리고, persistent mode에서는 AES-256-GCM encrypted user file에만 저장하는가
- server credential encryption key는 `.env`/secret manager 경계에만 있고 코드/문서/로그에 남지 않는가
- public server runner API는 HTTPS reverse proxy 뒤에서만 공개되고, raw `8787` HTTP port가 internet-open 상태가 아닌가
- public server runner API는 `BUCKS_COPY_REQUIRE_AUTH=true`를 강제하며 token 없는 `/users/me/*` 요청이 401로 실패하는가
- browser dashboard를 공개 도메인에 노출할 경우 `BUCKS_COPY_WEB_ACCESS_KEY` 기반 1차 access gate가 활성화되어 URL만 아는 사용자가 `/app`에 접근할 수 없는가

### Credential / Storage

- 로그아웃/Disconnect가 서버 session token을 revoke하고 process-memory/encrypted Bitget credential을 제거하는가
- encryption key가 없는 server runner 재시작 후 in-memory Bitget credential이 사라진 상태에서 account/position read가 409로 실패하고 재로그인이 필요한가
- encryption key가 있는 server runner 재시작 후 encrypted credential이 복원되어 account/position read가 유지되는가
- 로그아웃/credential 삭제 시 관련 local state가 정리되는가
- Live execution record와 민감 주문/account data가 구분되는가
- local market history DB에 API key, secret, passphrase, signature, raw private response가 저장되지 않는가
- local market history DB는 public candle/ticker/trade 기반 데이터와 최소 live audit metadata만 저장하는가
- server private polling은 raw private response가 아니라 normalized account/position snapshot만 저장하는가

### Bitget REST / WebSocket

- private REST 요청이 공식 signature 규칙을 따르며 login/account/position read-only와 live execution 경계가 섞이지 않았는가
- server account/position endpoint가 raw private response 전체가 아니라 UI에 필요한 normalized snapshot만 반환하는가
- WebSocket login signature와 REST signature 차이가 섞이지 않았는가
- ping/pong, reconnect, rate-limit backoff가 정의되어 있는가
- public channel과 private channel 사용 조건이 분리되어 있는가
- productType이 v1 범위인 `USDT-FUTURES` 밖으로 확장되지 않았는가
- WebSocket 구독이 Watchlist 심볼로만 제한되는가
- 한 연결당 50개 이하 구독 제한 또는 초과 validation이 있는가

### Trading Safety

- live order path가 credential 연결 + 서버 live 동의 + order execution env switch 전에는 비활성화되어 있는가
- server-side live gate가 explicit consent, loaded credential, fresh private snapshot, duplicate runner lock readiness를 모두 확인하는가
- server paper runner의 order path가 `BUCKS_COPY_LIVE_ORDER_EXECUTION_ENABLED=true`와 양수 `BUCKS_COPY_LIVE_ORDER_MARGIN_USDT` 없이는 비활성화되는가
- server paper runner는 private WebSocket을 포함하지 않고, live order/protection client가 gate 뒤에서만 호출되는가
- public server runner edge가 `/health`, `/auth/bitget/login`, `/users/me/*` 외 legacy local routes를 proxy하지 않는가
- public server runner edge가 web dashboard 공개 시 `/`, `/app`, `/web/access/*`만 추가로 proxy하고, legacy local routes를 여전히 공개하지 않는가
- strategy가 order API를 직접 호출하지 않는가
- Watchlist에 없는 심볼로 order intent가 만들어지지 않는가
- 다중 전략/시간봉이 동시에 signal을 만들 때 포트폴리오 중재 정책이 live order를 1개로 제한해 중복 주문과 과다 노출을 차단하는가
- 같은 symbol/side 포지션이 열려 있을 때 새 신호가 기존 포지션을 중복 진입/교체하지 않는가
- 반대 방향 동시 보유는 Bitget hedge mode에서만 의도대로 long/short 슬롯이 분리되는가
- 시간봉별 여러 전략 활성화가 Watchlist, 레버리지, 기존 포지션 제한을 우회하지 않는가
- Live 시작 시 이미 저장된 최신 completed 15m candle 신호가 즉시 실주문으로 이어지지 않도록 startup priming이 적용되고, forming candle은 entry 평가에서 제외되는가
- 자동매매 레버리지가 10x 이하로 제한되는가
- 손익비 2:1 미만, 레버리지 10x 초과, 또는 익절 기대 수익이 진입 taker + 익절 maker 수수료 이하인 signal이 차단되는가
- 레버리지 반영 손절 위험이 설정된 1회 최대 손실률보다 큰 signal은 차단 대신 포지션 투입비율이 축소되는가
- live entry size가 configured planned margin과 USDT available balance ratio 중 더 작은 쪽으로 제한되는가
- 수수료 모델이 market/taker와 limit/maker 가정을 명시하고, maker 체결을 보장할 수 없는 주문을 maker로 과대평가하지 않는가
- 진입 체결 후 TP1/TP2/SL 거래소-side 보호 주문이 모두 등록되기 전까지 protected 상태로 표시하지 않는가
- Bitget position snapshot의 TP/SL 누락을 live entry log로 보강할 때, 표시와 portfolio scoring에만 사용하고 거래소 보호주문 체결/이동 상태를 과대 확정하지 않는가
- 보유기간 만료 청산은 server-created live entry log로 symbol, side, strategy, timeframe을 매칭할 수 있는 포지션에만 적용되는가
- 보유기간 만료 청산이 발생한 monitor cycle에서 신규 진입 평가를 건너뛰어 close와 entry가 같은 주기에 충돌하지 않는가
- 진입 체결 응답 후 보호주문 설치 전에 position snapshot으로 실제 open position 존재를 확인하는가
- TP1 체결 후 남은 물량의 SL이 profit-lock 가격으로 이동되기 전까지 remaining position을 protected로 과대 표시하지 않는가
- TP/SL 보호 주문 등록 실패 시 실패한 주문별 최소 5회 재시도하고, 소진 시 fail-closed 정책으로 이어지는가
- fail-closed `close-positions` 호출 직전에 fresh position snapshot을 확인하고, 닫을 포지션이 없으면 시장가 청산 주문을 생략하는가
- TP/SL clientOid가 재시도 중복 주문을 줄일 수 있도록 안정적으로 생성되는가
- live order, rejected/fill-not-confirmed order, risk block이 구분되어 기록되는가
- 보호주문 재시도 소진 로그가 원문 private response 없이 sanitized Bitget code/message를 보존하는가
- 신호 변경으로 기존 포지션을 정리하는 close log가 raw order identifier 없이 redacted ID, 청산 직전 PnL, 승/패 판정만 남기는가
- 보유기간 만료 close log가 raw order identifier 없이 redacted ID와 `청산 근거`, 매매전략, 시간봉, 경과 봉수만 남기는가
- 잘못된 symbol/productType/timeframe 입력이 실패로 처리되는가
- `POST /api/v2/mix/order/place-order` 호출 경로가 서버 live 동의와 risk policy를 우회할 수 없는가

### Logging

- credential, signature, account balance 원문, raw order identifier, full order response를 남기지 않는가
- 실패 메시지가 사용자에게 필요한 수준으로만 정제되는가
- debug dump가 남아 있지 않은가

## 리뷰 산출물 형식

- 위험 수준: 높음 / 중간 / 낮음
- 발견 사항
- 왜 위험한지
- 수정 권장 방향
- 추가로 봐야 할 역할
