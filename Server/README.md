# BucksCopy Server

## 한글 요약

- 현재 실전 기준 엔진은 `Server/PaperRunnerPython/paper_runner.py`입니다.
- runner는 Bitget public REST로 `15m` candle을 받아 공용 JSON 파일에 저장하고, 사용자별 상태/control/log를 분리합니다.
- 저장 기본값은 개수 제한 없음(`BUCKS_COPY_CANDLE_LIMIT=0`)입니다. 1회 fetch는 Bitget API 한도 때문에 최대 `1000`개로 나누고, 오래된 candle은 history backfill로 여러 페이지를 이어 받습니다.
- Bitget API key, secret, passphrase는 `/auth/bitget/login` 후 서버 메모리에 올리고, `BUCKS_COPY_CREDENTIAL_ENCRYPTION_KEY`가 설정된 운영 환경에서는 AES-256-GCM으로 암호화해 사용자별 파일에 저장합니다.
- Bitget credential 원문, 서명 payload, private response 원문은 디스크/env/log에 저장하지 않습니다.

## Runtime Runner

Local one-shot check:

```bash
BUCKS_COPY_DATA_DIR=.server-data \
BUCKS_COPY_RUN_ONCE=true \
python3 Server/PaperRunnerPython/paper_runner.py
```

Docker one-shot check:

```bash
docker build -f Server/Dockerfile -t bucks-copy-paper-runner .
docker run --rm \
  -e BUCKS_COPY_RUN_ONCE=true \
  -v "$PWD/.server-data:/var/lib/bucks-copy" \
  bucks-copy-paper-runner
```

Server compose run from the repository root:

```bash
cp Server/env.paper.example .env
docker compose --env-file .env -f Server/docker-compose.paper.yml up -d --build
docker compose --env-file .env -f Server/docker-compose.paper.yml logs -f
```

Useful history settings:

```text
BUCKS_COPY_CANDLE_LIMIT=0
BUCKS_COPY_FETCH_CANDLE_LIMIT=1000
BUCKS_COPY_HISTORY_BACKFILL_PAGES_PER_CYCLE=100
```

`BUCKS_COPY_CANDLE_LIMIT=0` means the runner does not trim by candle count and
keeps backfilling until Bitget returns no older rows. `BUCKS_COPY_FETCH_CANDLE_LIMIT`
is only the per-request Bitget fetch size, so it should not be confused with the
total history available to strategies. `BUCKS_COPY_HISTORY_BACKFILL_PAGES_PER_CYCLE`
is a per-cycle request batch size, not a storage cap.

The compose API port is bound to `127.0.0.1` on the server by default. It is
intended for server-local checks or an SSH tunnel first, not direct internet
exposure.

```bash
curl http://127.0.0.1:8787/health
curl http://127.0.0.1:8787/users/me/status
curl 'http://127.0.0.1:8787/users/me/logs?limit=20'
curl 'http://127.0.0.1:8787/users/me/candles?symbol=BTCUSDT&limit=20'
curl http://127.0.0.1:8787/users/me/account
curl http://127.0.0.1:8787/users/me/positions
curl -X POST http://127.0.0.1:8787/users/me/control \
  -H 'Content-Type: application/json' \
  -d '{"enabled":false}'
curl http://127.0.0.1:8787/users/me/live/status
```

For local server-only checks without exposing the API publicly, keep an SSH
tunnel open from the client machine:

```bash
ssh -L 8787:127.0.0.1:8787 ubuntu@<server-public-ip>
```

## User Scope And Auth

Market candles are shared server-wide:

- `candles-{symbol}-15m.json`: normalized Bitget public OHLCV candles

Paper bot state is user-scoped:

- `users/{userID}/paper-runner-control.json`
- `users/{userID}/paper-runner-status.json`
- `users/{userID}/paper-runner-evaluations.jsonl`
- `users/{userID}/trade-event-logs.jsonl`

Without an auth file, the API uses the local default user `local-admin` and
is still bound to server-local `127.0.0.1` by Docker Compose. To enable token
auth, create `/home/ubuntu/bucks-copy-server/data/auth-users.json` on the
server with a long random token:

```json
{
  "users": [
    {
      "userID": "local-admin",
      "token": "replace-with-a-random-token-at-least-32-characters"
    }
  ]
}
```

Then set `BUCKS_COPY_REQUIRE_AUTH=true` in `.env` and restart:

```bash
chmod 600 /home/ubuntu/bucks-copy-server/data/auth-users.json
docker compose --env-file .env -f Server/docker-compose.paper.yml up -d --build
curl -H 'Authorization: Bearer <token>' http://127.0.0.1:8787/users/me/status
```

For always-on server use, set a high-entropy credential encryption key in
`.env` before accepting Bitget logins:

```bash
python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
```

```text
BUCKS_COPY_CREDENTIAL_ENCRYPTION_KEY=<generated-random-key>
```

When this key is set, `/auth/bitget/login` stores each Bitget credential as
`users/{userID}/bitget-credential.enc.json` using AES-256-GCM. The runner
restores those credentials on container restart so account/position reads and
future server-side automation can continue without any local desktop client.
The `.env` file and encrypted credential files must stay on the server and must
not be committed.

Browser/API clients use:

```bash
BUCKS_COPY_SERVER_API_BASE_URL=http://127.0.0.1:8787
BUCKS_COPY_SERVER_API_TOKEN=<token>
```

## Public HTTPS API

The public API mode is for using the server without an SSH tunnel. It requires a
real DNS name pointing to the Lightsail static IP. Do not expose the raw
`8787` port to the internet.

1. Create a DNS `A` record such as `api.example.com -> <Lightsail static IP>`.
2. In the Lightsail firewall, allow inbound `TCP 80` and `TCP 443`.
3. Keep `SSH 22` restricted to your IP when possible. Keep database or Redis
   ports closed.
4. Keep `BUCKS_COPY_REQUIRE_AUTH=true`. Existing users may come from
   `/home/ubuntu/bucks-copy-server/data/auth-users.json`; new users can be
   added by `/auth/bitget/login`.

Set these in `.env`:

```bash
BUCKS_COPY_REQUIRE_AUTH=true
BUCKS_COPY_SERVER_DOMAIN=api.example.com
BUCKS_COPY_HOST_CADDY_DATA_DIR=/home/ubuntu/bucks-copy-server/caddy-data
BUCKS_COPY_HOST_CADDY_CONFIG_DIR=/home/ubuntu/bucks-copy-server/caddy-config
```

Optional web access gate for browser use:

```bash
BUCKS_COPY_WEB_ACCESS_KEY=<the-key-you-type-before-opening-the-dashboard>
BUCKS_COPY_WEB_ACCESS_SESSION_SECRET=<generated-random-string-at-least-32-characters>
BUCKS_COPY_WEB_ACCESS_SESSION_SECONDS=43200
BUCKS_COPY_WEB_ACCESS_COOKIE_SECURE=true
```

When `BUCKS_COPY_WEB_ACCESS_KEY` is set, `/` and `/app` require that key before
showing the web dashboard shell. If the key is not set, the web dashboard fails
closed with `503` instead of opening. A successful key check creates an HttpOnly
`SameSite=Strict` cookie. This gate is only the first web-page lock; Bitget login
and `/users/me/*` bearer-token auth remain separate and still protect private
API data.

Start the runner with the HTTPS proxy:

```bash
docker compose --env-file .env \
  -f Server/docker-compose.paper.yml \
  -f Server/docker-compose.https.yml \
  up -d --build
```

Smoke check:

```bash
curl https://api.example.com/health
curl -i https://api.example.com/app
curl -i https://api.example.com/users/me/status
curl -i https://api.example.com/users/me/status \
  -H 'Authorization: Bearer <token>'
```

Expected result:

- `/health`: `200 OK`
- `/app` with web access gate enabled and no cookie: `401`
- `/users/me/status` without token: `401`
- `/users/me/status` with token: `200 OK`

The browser/server API base URL becomes:

```text
https://api.example.com
```

Only `/health`, `/auth/bitget/login`, and `/users/me/*` are proxied by Caddy.
Legacy local routes such as `/status`, `/control`, `/logs`, and `/candles`
remain available only through the server-local `127.0.0.1:8787` bind.

The web login flow posts Bitget API key, secret, and passphrase to:

```bash
curl -X POST https://api.example.com/auth/bitget/login \
  -H 'Content-Type: application/json' \
  -d '{"apiKey":"...","secretKey":"...","passphrase":"..."}'
```

The runner validates the credential with Bitget USDT-M Futures account read,
creates or reuses a user-scoped bearer token in `auth-users.json`, and returns
that browser/API session token. If `BUCKS_COPY_CREDENTIAL_ENCRYPTION_KEY` is set, the
runner also writes an AES-256-GCM encrypted credential record under the user
directory and restores it on restart. Without that key, credentials remain
memory-only.

After a successful login, the browser client can use the server session token to read:

```bash
curl https://api.example.com/users/me/account \
  -H 'Authorization: Bearer <token>'
curl https://api.example.com/users/me/positions \
  -H 'Authorization: Bearer <token>'
```

The runner also refreshes normalized account/position snapshots in the
background every `BUCKS_COPY_PRIVATE_POLL_SECONDS` seconds for users with a
restored Bitget credential. The snapshot is stored as:

```text
users/{userID}/private-snapshot.json
```

This file contains only normalized account and position fields used by the web UI,
not raw Bitget private responses, signatures, headers, API secret, or
passphrase.

Server-side live trading has a separate safety gate. The runner can now attach
the Bitget order path behind that gate, but order submission remains disabled
unless the deployment explicitly sets both the live execution switch and a
positive per-entry margin:

```bash
curl https://api.example.com/users/me/live/status \
  -H 'Authorization: Bearer <token>'
curl -X POST https://api.example.com/users/me/live/control \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -d '{"enabled":true,"acknowledgedRisk":true}'
```

The live gate requires explicit consent, a loaded Bitget credential, a fresh
private snapshot, and an available live runner lock. `orderExecutionEnabled`
is still `false` while either `BUCKS_COPY_LIVE_ORDER_EXECUTION_ENABLED=false`
or `BUCKS_COPY_LIVE_ORDER_MARGIN_USDT=0`.

When enabled, a server signal uses this sequence:

1. Set leverage for the signal symbol.
2. Submit a Bitget USDT-M Futures market entry.
3. Confirm the entry fill through order detail.
4. Refresh positions and verify that the open position exists.
5. Register TP1, TP2, and SL through Bitget TPSL plan orders.
6. If protection registration is exhausted after retries, refresh positions and
   call `close-positions` only if the position is still open.

The deployment variables are:

```text
BUCKS_COPY_LIVE_ORDER_EXECUTION_ENABLED=false
BUCKS_COPY_LIVE_ORDER_MARGIN_USDT=0
BUCKS_COPY_LIVE_AVAILABLE_BALANCE_RATIO=1
BUCKS_COPY_LIVE_MARGIN_MODE=isolated
BUCKS_COPY_LIVE_POSITION_MODE=hedge
```

`BUCKS_COPY_LIVE_AVAILABLE_BALANCE_RATIO=1` means the live executor may size up
to 100% of current USDT available balance, still capped by
`BUCKS_COPY_LIVE_ORDER_MARGIN_USDT` and Bitget contract minimum/step rules.

To log out and revoke the current browser/API session token:

```bash
curl -X DELETE https://api.example.com/users/me/session \
  -H 'Authorization: Bearer <token>'
```

Logout removes the bearer token, the in-memory Bitget credential, and the
encrypted credential file for that user. User-scoped paper runner files remain
on disk.

If `BUCKS_COPY_CREDENTIAL_ENCRYPTION_KEY` is not configured and the container
restarts, `auth-users.json` can still recognize the browser/API session token, but the
in-memory Bitget credential is gone. In that case private account/position reads
return `409` and the client must perform Bitget login again.

If the mounted data/log folders were created by an earlier container attempt
with restrictive permissions, reset ownership once:

```bash
sudo chown -R ubuntu:ubuntu ~/bucks-copy-server/data ~/bucks-copy-server/logs
chmod -R u+rwX ~/bucks-copy-server/data ~/bucks-copy-server/logs
```

The runner writes JSON/JSONL files under `BUCKS_COPY_DATA_DIR`:

- `candles-{symbol}-15m.json`: normalized Bitget public OHLCV candles
- `auth-users.json`: optional bearer-token user mapping, not committed
- `users/{userID}/bitget-credential.enc.json`: optional AES-256-GCM encrypted Bitget credential, not committed
- `users/{userID}/private-snapshot.json`: normalized read-only account/position snapshot
- `users/{userID}/server-live-control.json`: explicit server live consent state, default disabled
- `users/{userID}/server-live-lock.json`: future live runner lock heartbeat
- `users/{userID}/trade-event-logs.jsonl`: user paper signal and heartbeat records
- `users/{userID}/paper-runner-status.json`: latest user paper runner status
- `users/{userID}/paper-runner-evaluations.jsonl`: duplicate evaluation guard by `symbol/timeframe/strategy/openTime`
- `users/{userID}/paper-runner-control.json`: user paper evaluation ON/OFF state

## Safety Boundary

- Private Bitget REST is limited to login validation plus read-only account and
  position snapshots for the authenticated user.
- Server-side private polling stores normalized account/position snapshots only.
- Server-side live order APIs are behind live consent, loaded credential, fresh
  private snapshot, duplicate runner lock, environment execution switch, and
  positive per-entry margin checks.
- Bitget API key, secret, and passphrase are process-memory only unless
  `BUCKS_COPY_CREDENTIAL_ENCRYPTION_KEY` enables AES-256-GCM encrypted
  user-scoped credential storage.
- `DELETE /users/me/session` revokes the browser/API bearer token and clears the
  process-memory and encrypted Bitget credential for that user.
- No WebSocket private login.
- No order placement by default. Production `.env` must explicitly opt in with
  `BUCKS_COPY_LIVE_ORDER_EXECUTION_ENABLED=true` and a positive
  `BUCKS_COPY_LIVE_ORDER_MARGIN_USDT`.
- No Bitget API key/secret/passphrase disk, env, or log storage.
- No unprotected live execution: entry fill must be followed by TP1/TP2/SL
  protection or fail-closed close handling.
