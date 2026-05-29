# BucksCopy

macOS native crypto auto-trading app foundation for Bitget USDT-M Futures.

## Project Defaults

| Area | Decision |
| --- | --- |
| App stack | SwiftUI native macOS app |
| Project harness | Tuist + Xcode |
| Exchange | Bitget |
| Initial market | Bitget USDT-M Futures (`productType=USDT-FUTURES`) |
| Trading mode | Live auto-trading with explicit Connect + consent + Start Live gate |
| Data | Bitget REST and WebSocket v2 |
| Local market history | SQLite-backed candle cache for Watchlist symbols |
| Candle timeframes | 15m, 1H, 4H, 12H, 1D |
| Symbol activation | Load the full USDT-M Futures catalog, then trade only user-selected Watchlist symbols |
| Dashboard v1 | Connect-only API credential panel, account summary, Watchlist, interactive Bitget-backed SwiftUI Canvas candles, real positions, Live bot log |

## Codex Skill / Docs

| Skill | Role | Runtime agent |
| --- | --- | --- |
| [bucks-copy-macos-structure](./.codex/skills/bucks-copy-macos-structure/SKILL.md) | macOS structure and placement rules | none |
| [bucks-copy-bitget-integration](./.codex/skills/bucks-copy-bitget-integration/SKILL.md) | Bitget REST/WS auth, DTO, reconnect, rate-limit safety | none |
| [bucks-copy-trading-engine](./.codex/skills/bucks-copy-trading-engine/SKILL.md) | candle aggregation, strategy boundaries, live execution safety | none |
| [bucks-copy-l1-planner-orchestrator](./.codex/skills/bucks-copy-l1-planner-orchestrator/SKILL.md) | route complex work and prepare handoff | [toml](./.codex/agents/bucks-copy-l1-planner-orchestrator.toml) |
| [bucks-copy-l2-architect](./.codex/skills/bucks-copy-l2-architect/SKILL.md) | layer and boundary review | [toml](./.codex/agents/bucks-copy-l2-architect.toml) |
| [bucks-copy-l2-security](./.codex/skills/bucks-copy-l2-security/SKILL.md) | secrets, keychain, auth, logging, trust-boundary review | [toml](./.codex/agents/bucks-copy-l2-security.toml) |
| [bucks-copy-l2-tdd-guide](./.codex/skills/bucks-copy-l2-tdd-guide/SKILL.md) | acceptance scenarios and minimum validation | [toml](./.codex/agents/bucks-copy-l2-tdd-guide.toml) |
| [bucks-copy-l2-code-reviewer](./.codex/skills/bucks-copy-l2-code-reviewer/SKILL.md) | findings-first code review | [toml](./.codex/agents/bucks-copy-l2-code-reviewer.toml) |
| [bucks-copy-l3-build-fixer](./.codex/skills/bucks-copy-l3-build-fixer/SKILL.md) | build and target wiring recovery | [toml](./.codex/agents/bucks-copy-l3-build-fixer.toml) |
| [bucks-copy-l3-doc-writer](./.codex/skills/bucks-copy-l3-doc-writer/SKILL.md) | canonical docs update | [toml](./.codex/agents/bucks-copy-l3-doc-writer.toml) |
| [bucks-copy-l3-migration](./.codex/skills/bucks-copy-l3-migration/SKILL.md) | staged structural migration | [toml](./.codex/agents/bucks-copy-l3-migration.toml) |

## Canonical Docs

| Situation | Start Here |
| --- | --- |
| Repository rules | [AGENTS.md](./AGENTS.md) |
| Document map | [docs/00-governance/doc-map.md](./docs/00-governance/doc-map.md) |
| Architecture and layers | [docs/20-architecture/system-overview.md](./docs/20-architecture/system-overview.md) |
| Decision history | [docs/20-architecture/decision-log.md](./docs/20-architecture/decision-log.md) |
| Security | [docs/30-quality/security-checklist.md](./docs/30-quality/security-checklist.md) |
| Test strategy | [docs/30-quality/test-strategy.md](./docs/30-quality/test-strategy.md) |
| Skill and agent routing | [docs/40-agents/orchestration-model.md](./docs/40-agents/orchestration-model.md), [docs/40-agents/routing-matrix.md](./docs/40-agents/routing-matrix.md), [docs/40-agents/skill-catalog.md](./docs/40-agents/skill-catalog.md) |
| Migration | [docs/50-migration/migration-playbook.md](./docs/50-migration/migration-playbook.md) |
| Code style | [docs/CODE_CONVENTION.md](./docs/CODE_CONVENTION.md) |

## Bitget References

- [API Domain](https://www.bitget.com/api-doc/common/domain)
- [REST API / Signature](https://www.bitget.com/api-doc/classic/quickStart/intro)
- [WebSocket API](https://www.bitget.com/api-doc/classic/quickStart/websocket-intro)
- [Futures Contract Config](https://www.bitget.com/api-doc/classic/contract/market/Get-All-Symbols-Contracts)
- [Futures Candle Data](https://www.bitget.com/api-doc/classic/contract/market/Get-Candle-Data)
- [Futures Historical Candle Data](https://www.bitget.com/api-doc/contract/market/Get-History-Candle-Data)
- [Futures Candlestick WebSocket](https://www.bitget.com/api-doc/classic/contract/websocket/public/Candlesticks-Channel)
- [Futures Place Order](https://www.bitget.com/api-doc/contract/trade/Place-Order)
- [Futures Flash Close Position](https://www.bitget.com/api-doc/contract/trade/Flash-Close-Position)
- [Futures Stop-profit and Stop-loss Plan Orders](https://www.bitget.com/api-doc/contract/plan/Place-Tpsl-Order)

## Bitget v1 Scope

- `GET /api/v2/mix/market/contracts?productType=USDT-FUTURES` loads the USDT-M Futures symbol catalog.
- `GET /api/v2/mix/market/candles` and `GET /api/v2/mix/market/history-candles` seed and gap-fill local candle history.
- `GET /api/v2/mix/account/accounts` validates saved API credentials.
- `GET /api/v2/mix/position/all-position` loads read-only real position snapshots.
- `Connect` stores credentials in Keychain and validates private API access in one action; saved credentials auto-connect on the next launch.
- Only `symbolStatus=normal` symbols whose `supportMarginCoins` include `USDT` are valid Watchlist candidates.
- After the initial REST candle backfill, the selected Watchlist symbol/timeframe starts a public WebSocket candle subscription and upserts live candle pushes into SQLite.
- Public WebSocket subscriptions are created only for Watchlist symbols and are replaced when the selected symbol or timeframe changes.
- One WebSocket connection should keep subscriptions at or below 50 channels; larger Watchlists must be split or rejected by validation.
- Closed Watchlist candles are persisted locally so restart/warmup does not depend only on the exchange's current queryable range.
- The candle chart shows one price pane with a right-side price axis, latest-price line, continuous candle-width zoom, and drag panning.
- `POST /api/v2/mix/order/place-order` is used only after credential connection, explicit live consent, risk policy acceptance, and portfolio arbitration.
- Live entry sequence is set leverage -> market entry -> fill confirmation -> TP1/TP2/SL exchange-side protection; protection retry exhaustion triggers fail-closed close-position.

## App Commands

```bash
tuist generate --no-open
xcodebuild -workspace BucksCopy.xcworkspace -scheme BucksCopy -destination 'platform=macOS' test
open BucksCopy.xcworkspace
```

## Harness Checks

```bash
python3 scripts/ci/check_agent_config.py
python3 scripts/ci/check_agent_routing.py
python3 scripts/ci/check_agent_trace.py
```
