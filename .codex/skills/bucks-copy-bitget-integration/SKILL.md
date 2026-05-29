---
name: bucks-copy-bitget-integration
description: >
  Use for BucksCopy Bitget REST/WebSocket integration work, including official
  endpoint lookup, HMAC/RSA signature boundaries, API key/passphrase handling,
  USDT-M Futures contract config, Watchlist-scoped subscriptions, WebSocket
  login, ping/pong, reconnect, rate-limit behavior, DTO mapping, and no-secret
  logging.
---

# BucksCopy Bitget Integration

## 읽기 순서

1. `AGENTS.md`
2. `docs/30-quality/security-checklist.md`
3. `docs/20-architecture/system-overview.md`
4. Official Bitget docs linked in `README.md`

## 핵심 규칙

- Use Classic Futures v2 mix API for v1.
- Treat USDT-M Futures as `productType=USDT-FUTURES`.
- Use official Bitget docs for endpoint and signature details.
- Keep credential storage in Keychain-facing Data adapter code.
- Keep REST/WS DTOs in Data and map into Domain contracts.
- Use local market history storage for Watchlist candle seeding and startup gap fill.
- Implement ping/pong, reconnect, and rate-limit handling for WebSocket work.
- Load contract config from `GET /api/v2/mix/market/contracts`.
- Expose only `symbolStatus=normal` symbols with `USDT` in `supportMarginCoins` as Watchlist candidates.
- Subscribe only Watchlist symbols and keep one connection at or below 50 channels unless an explicit split strategy is implemented.
- Never log API key, secret, passphrase, signature, raw private headers, or full account/order responses.

## 확인 포인트

- REST signature and WebSocket login signature are not mixed.
- Public and private WebSocket channel requirements are separated.
- Product scope defaults to USDT-M Futures / `USDT-FUTURES`.
- Watchlist membership gates subscription, strategy, and live order eligibility.
- REST candle backfill is idempotent with local history by symbol/granularity/open time.
- Failure paths preserve redacted errors and retry/backoff state.
