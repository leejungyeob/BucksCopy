# Server Runner Handoff

## 한글 요약

- 이 문서는 다른 노트북 또는 다른 Codex 세션에서 `BucksCopy` server runner 작업을 이어받기 위한 인수인계 문서입니다.
- 현재 브랜치는 `codex/server-paper-runner-15m`이고, 최신 핵심 커밋은 `348bb76 서버 read-only 계정 조회 추가`입니다.
- 현재 서버는 paper-only입니다. 실거래 주문, private WebSocket, 보호주문 설치, persistent Bitget credential storage는 아직 구현하지 않았습니다.

## Current Repository State

| 항목 | 값 |
| --- | --- |
| GitHub repo | `leejungyeob/BucksCopy` |
| Working branch | `codex/server-paper-runner-15m` |
| Latest handoff commit | `348bb76 서버 read-only 계정 조회 추가` |
| Server domain | `https://api.buckscopy.com` |
| Server host user/path | `ubuntu`, `/home/ubuntu/bucks-copy-server/app/BucksCopy` |
| Server runtime | Docker Compose, Python paper runner, Caddy HTTPS proxy |
| Product scope | Bitget USDT-M Futures, `productType=USDT-FUTURES` |
| Runtime candle scope | BTCUSDT/ETHUSDT `15m` closed candles |

Recent commits to understand first:

```text
348bb76 서버 read-only 계정 조회 추가
7987f50 서버 Bitget 로그인으로 토큰 발급
f4336f5 서버 paper API HTTPS 프록시 추가
1d987d6 앱 서버 runner 연결 설정 저장
1182b79 서버 paper runner 사용자 상태 분리
6d5942d Mac 앱 서버 runner 상태 연동
04b9efc 서버 페이퍼 러너 상태 API 추가
94975c6 서버 페이퍼 러너를 Python으로 전환
```

## What Is Already Done

1. AWS Lightsail Ubuntu server was created and Docker was installed.
2. Server directories were prepared under `/home/ubuntu/bucks-copy-server`.
3. Cloudflare domain `buckscopy.com` was configured with DNS record:
   - `api.buckscopy.com -> 3.37.37.69`
4. Lightsail firewall was opened for:
   - `22` SSH
   - `80` HTTP for Caddy certificate challenge
   - `443` HTTPS for the public API
5. Raw runner port `8787` is not publicly exposed. Docker binds it to server-local `127.0.0.1`.
6. Caddy reverse proxy exposes only:
   - `/health`
   - `/auth/bitget/login`
   - `/users/me/*`
7. Server paper runner collects shared public market candles:
   - `BTCUSDT 15m`
   - `ETHUSDT 15m`
8. User-scoped paper state is separated under `users/{userID}/`.
9. macOS app can save server endpoint/session token through the server runner configuration store.
10. API credential input in the app now acts as server login when a server endpoint exists.

## Current Auth And Credential Boundary

The current flow is intentionally narrow:

1. User enters Bitget `APIKey`, `SecretKey`, and `Passphrase` in the macOS app.
2. App posts them to `POST /auth/bitget/login`.
3. Server validates the credential with a Bitget USDT-M Futures account read.
4. Server creates or reuses a user-scoped bearer token in `auth-users.json`.
5. App stores only the server endpoint/token in Keychain.
6. Server keeps Bitget API key/secret/passphrase in process memory only.
7. App can then read account/position snapshots through:
   - `GET /users/me/account`
   - `GET /users/me/positions`

Important limitation:

- If the `paper-runner` container restarts, the server session token can still exist, but the in-memory Bitget credential is gone.
- In that case account/position endpoints return `409`, and the app should ask the user to Bitget-login again.
- This is deliberate until encrypted persistent credential storage is designed.

Never commit or paste:

- Bitget API key
- Bitget secret key
- Bitget passphrase
- server bearer token
- private request signature/header payloads
- raw private Bitget responses

## Deploy From Server

SSH into the Lightsail instance, then run:

```bash
cd ~/bucks-copy-server/app/BucksCopy
git pull --ff-only origin codex/server-paper-runner-15m
docker compose --env-file .env \
  -f Server/docker-compose.paper.yml \
  -f Server/docker-compose.https.yml \
  up -d --build
```

Check containers:

```bash
docker compose --env-file .env \
  -f Server/docker-compose.paper.yml \
  -f Server/docker-compose.https.yml \
  ps
```

Check HTTPS:

```bash
curl https://api.buckscopy.com/health
curl -i https://api.buckscopy.com/users/me/status
```

Expected:

- `/health` returns `200`.
- `/users/me/status` without bearer token returns `401`.

After logging in through the app, private read-only checks can be done with a valid token:

```bash
curl https://api.buckscopy.com/users/me/account \
  -H 'Authorization: Bearer <token>'
curl https://api.buckscopy.com/users/me/positions \
  -H 'Authorization: Bearer <token>'
```

Do not paste the real token into docs, commits, logs, or chat unless the user explicitly chooses to rotate it immediately afterward.

## Local Mac Handoff Steps

On a different Mac:

```bash
git clone https://github.com/leejungyeob/BucksCopy.git
cd BucksCopy
git checkout codex/server-paper-runner-15m
git pull --ff-only origin codex/server-paper-runner-15m
```

Then open the project in Xcode or run the standard verification:

```bash
python3 -m py_compile Server/PaperRunnerPython/paper_runner.py
xcodebuild -project BucksCopy.xcodeproj -scheme BucksCopy -destination 'platform=macOS' test -quiet
```

App smoke flow:

1. Launch the macOS app.
2. Confirm Server Runner URL is `https://api.buckscopy.com`.
3. Enter Bitget API key, secret, passphrase in the API Credential panel.
4. Press Connect.
5. Confirm Server Runner shows connected/on state.
6. Confirm paper status/logs/candles load.
7. Confirm account/positions load after server login.

## Known Server Data Paths

Server `.env` should point host data to persistent folders:

```text
BUCKS_COPY_HOST_DATA_DIR=/home/ubuntu/bucks-copy-server/data
BUCKS_COPY_HOST_LOG_DIR=/home/ubuntu/bucks-copy-server/logs
BUCKS_COPY_HOST_CADDY_DATA_DIR=/home/ubuntu/bucks-copy-server/caddy-data
BUCKS_COPY_HOST_CADDY_CONFIG_DIR=/home/ubuntu/bucks-copy-server/caddy-config
BUCKS_COPY_SERVER_DOMAIN=api.buckscopy.com
BUCKS_COPY_REQUIRE_AUTH=true
```

Runner data files:

```text
candles-BTCUSDT-15m.json
candles-ETHUSDT-15m.json
auth-users.json
users/{userID}/paper-runner-control.json
users/{userID}/paper-runner-status.json
users/{userID}/paper-runner-evaluations.jsonl
users/{userID}/trade-event-logs.jsonl
```

`auth-users.json` stores app session tokens only. It must not store Bitget secret/passphrase.

## Current Resource Snapshot

Last known Lightsail resource check from the server:

```text
Disk: 58G total, 6.9G used, 51G available
Memory: 1.9Gi total, about 1.3Gi available
CPU: 2 cores
Docker image: about 3.5GB
Docker build cache: about 4.4GB
Runner data/logs: still tiny at current scale
```

For BTC/ETH 15m candles, disk is not the near-term bottleneck. Multi-user private polling, WebSocket fan-out, and live order reconciliation will increase CPU/memory/network cost before candle JSON storage becomes a problem.

## Safety Boundary

Current server is allowed to:

- collect public Bitget `15m` candles
- evaluate paper strategies
- store shared public market data
- store user-scoped paper status/control/logs
- validate Bitget credential during login
- read account/position snapshots after login

Current server is not allowed to:

- place live orders
- open private WebSocket sessions
- store Bitget credential persistently
- register TP/SL protection orders
- run live execution without explicit user consent and fail-closed protection logic

## Next Work

Recommended order:

1. Deploy latest branch to Lightsail and smoke-test `https://api.buckscopy.com`.
2. Run the app from a Mac and verify Bitget login -> account/positions -> server runner panel.
3. Improve UX so the server URL/token mechanics are hidden from normal users.
4. Add session logout/revocation endpoint and app-side logout cleanup.
5. Decide encrypted server credential storage before any always-on private polling.
6. Add account/position polling policy per user, with low-frequency refresh and manual refresh.
7. Only after that, design server-side live execution:
   - explicit live consent
   - duplicate runner lock
   - exchange-side TP1/TP2/SL protection
   - retry and fail-closed market close
   - position reconciliation
   - sanitized live audit logs

## Rollback

If the newest server/app behavior breaks:

```bash
cd ~/bucks-copy-server/app/BucksCopy
git checkout 7987f50
docker compose --env-file .env \
  -f Server/docker-compose.paper.yml \
  -f Server/docker-compose.https.yml \
  up -d --build
```

That rollback keeps HTTPS and Bitget login token issuance, but removes read-only account/position endpoints.

To go further back to the HTTPS edge without server Bitget login:

```bash
git checkout f4336f5
```

Use rollback only as an operational recovery step. For continued development, return to `codex/server-paper-runner-15m`.
