# Security Checklist

## 한글 요약

- Bitget API key, secret, passphrase, order/account data는 고위험 민감정보입니다.
- v1은 Paper trading 우선이며 live order는 명시 정책 전까지 차단합니다.
- Security 역할은 auth, token, Keychain, logging, URLSession/WebSocket, order boundary를 중점 검토합니다.

## 기본 원칙

1. Secret은 최소 저장, 최소 노출합니다.
2. Keychain 외 저장소에 credential을 넣지 않습니다.
3. 로그는 원인 파악에 필요한 최소 metadata만 남깁니다.
4. 외부 응답은 DTO 경계에서 검증/매핑한 뒤 사용합니다.
5. live execution은 명시 정책 전까지 구현/활성화하지 않습니다.

## 체크리스트

### Secrets / Config

- API key, secret, passphrase가 코드/문서/fixture/log에 하드코딩되지 않았는가
- `.env`, local config, sample 값이 실제 credential처럼 보이지 않는가
- 서명 payload, signature, raw header가 로그에 남지 않는가

### Keychain / Storage

- credential 저장/삭제가 Keychain-facing Data adapter를 통해서만 이뤄지는가
- 로그아웃/credential 삭제 시 관련 local state가 정리되는가
- Paper execution record와 민감 주문/account data가 구분되는가
- local market history DB에 API key, secret, passphrase, signature, raw private response가 저장되지 않는가
- local market history DB는 public candle/ticker/trade 기반 데이터와 최소 paper audit 데이터만 저장하는가

### Bitget REST / WebSocket

- private REST 요청이 공식 signature 규칙을 따르는가
- WebSocket login signature와 REST signature 차이가 섞이지 않았는가
- ping/pong, reconnect, rate-limit backoff가 정의되어 있는가
- public channel과 private channel 사용 조건이 분리되어 있는가
- productType이 v1 범위인 `USDT-FUTURES` 밖으로 확장되지 않았는가
- WebSocket 구독이 Watchlist 심볼로만 제한되는가
- 한 연결당 50개 이하 구독 제한 또는 초과 validation이 있는가

### Trading Safety

- live order path가 기본 비활성화되어 있는가
- strategy가 order API를 직접 호출하지 않는가
- Watchlist에 없는 심볼로 order intent가 만들어지지 않는가
- 다중 전략이 같은 symbol/timeframe에서 동시에 signal을 만들 때 중복 주문과 과다 노출이 정책적으로 차단되는가
- 시간봉별 여러 전략 활성화가 Watchlist, 레버리지, 기존 포지션 제한을 우회하지 않는가
- 자동매매 레버리지가 10x 이하로 제한되는가
- 손익비 2:1 미만, 레버리지 10x 초과, 또는 익절 기대 수익이 진입 taker + 익절 maker 수수료 이하인 signal이 차단되는가
- 레버리지 반영 손절 위험이 설정된 1회 최대 손실률보다 큰 signal은 차단 대신 포지션 투입비율이 축소되는가
- 수수료 모델이 market/taker와 limit/maker 가정을 명시하고, maker 체결을 보장할 수 없는 주문을 maker로 과대평가하지 않는가
- 진입 체결 후 TP/SL 거래소-side 보호 주문이 모두 등록되기 전까지 protected 상태로 표시하지 않는가
- TP/SL 보호 주문 등록 실패 시 실패한 주문별 최소 5회 재시도하고, 소진 시 fail-closed 정책으로 이어지는가
- TP/SL clientOid가 재시도 중복 주문을 줄일 수 있도록 안정적으로 생성되는가
- paper fill, rejected order, risk block이 구분되어 기록되는가
- 잘못된 symbol/productType/timeframe 입력이 실패로 처리되는가
- `POST /api/v2/mix/order/place-order` 호출 경로가 future live policy 전까지 실패로 닫혀 있는가

### Logging

- credential, signature, account balance 원문, full order response를 남기지 않는가
- 실패 메시지가 사용자에게 필요한 수준으로만 정제되는가
- debug dump가 남아 있지 않은가

## 리뷰 산출물 형식

- 위험 수준: 높음 / 중간 / 낮음
- 발견 사항
- 왜 위험한지
- 수정 권장 방향
- 추가로 봐야 할 역할
