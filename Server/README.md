# BucksCopy Server

## 한글 요약

- 현재 서버 단계는 실거래가 아니라 `paper-runner`입니다.
- runner는 Bitget public REST로 `15m` candle만 받아 공용 JSON 파일에 저장하고, 사용자별 paper 상태/control/log를 분리합니다.
- Bitget API key, secret, passphrase는 아직 이 서버 배포에 넣지 않습니다.

## Paper Runner

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

The compose API port is bound to `127.0.0.1` on the server by default. It is
intended for server-local checks or an SSH tunnel first, not direct internet
exposure.

```bash
curl http://127.0.0.1:8787/health
curl http://127.0.0.1:8787/users/me/status
curl 'http://127.0.0.1:8787/users/me/logs?limit=20'
curl 'http://127.0.0.1:8787/users/me/candles?symbol=BTCUSDT&limit=20'
curl -X POST http://127.0.0.1:8787/users/me/control \
  -H 'Content-Type: application/json' \
  -d '{"enabled":false}'
```

To point the macOS app at the server without exposing the API publicly, keep an
SSH tunnel open on the Mac:

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

The macOS app reads:

```bash
BUCKS_COPY_SERVER_API_BASE_URL=http://127.0.0.1:8787
BUCKS_COPY_SERVER_API_TOKEN=<token>
```

## Public HTTPS API

The public API mode is for using the app without an SSH tunnel. It requires a
real DNS name pointing to the Lightsail static IP. Do not expose the raw
`8787` port to the internet.

1. Create a DNS `A` record such as `api.example.com -> <Lightsail static IP>`.
2. In the Lightsail firewall, allow inbound `TCP 80` and `TCP 443`.
3. Keep `SSH 22` restricted to your IP when possible. Keep database or Redis
   ports closed.
4. Keep `/home/ubuntu/bucks-copy-server/data/auth-users.json` present and
   `BUCKS_COPY_REQUIRE_AUTH=true`.

Set these in `.env`:

```bash
BUCKS_COPY_REQUIRE_AUTH=true
BUCKS_COPY_SERVER_DOMAIN=api.example.com
BUCKS_COPY_HOST_CADDY_DATA_DIR=/home/ubuntu/bucks-copy-server/caddy-data
BUCKS_COPY_HOST_CADDY_CONFIG_DIR=/home/ubuntu/bucks-copy-server/caddy-config
```

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
curl -i https://api.example.com/users/me/status
curl -i https://api.example.com/users/me/status \
  -H 'Authorization: Bearer <token>'
```

Expected result:

- `/health`: `200 OK`
- `/users/me/status` without token: `401`
- `/users/me/status` with token: `200 OK`

The macOS app server URL becomes:

```text
https://api.example.com
```

Only `/health` and `/users/me/*` are proxied by Caddy. Legacy local routes such
as `/status`, `/control`, `/logs`, and `/candles` remain available only through
the server-local `127.0.0.1:8787` bind.

If the mounted data/log folders were created by an earlier container attempt
with restrictive permissions, reset ownership once:

```bash
sudo chown -R ubuntu:ubuntu ~/bucks-copy-server/data ~/bucks-copy-server/logs
chmod -R u+rwX ~/bucks-copy-server/data ~/bucks-copy-server/logs
```

The runner writes JSON/JSONL files under `BUCKS_COPY_DATA_DIR`:

- `candles-{symbol}-15m.json`: normalized Bitget public OHLCV candles
- `auth-users.json`: optional bearer-token user mapping, not committed
- `users/{userID}/trade-event-logs.jsonl`: user paper signal and heartbeat records
- `users/{userID}/paper-runner-status.json`: latest user paper runner status
- `users/{userID}/paper-runner-evaluations.jsonl`: duplicate evaluation guard by `symbol/timeframe/strategy/openTime`
- `users/{userID}/paper-runner-control.json`: user paper evaluation ON/OFF state

## Safety Boundary

- No private Bitget REST calls.
- No WebSocket private login.
- No order placement.
- No credential storage.
- No live execution until a separate explicit server-side consent and protection-order flow is implemented.
