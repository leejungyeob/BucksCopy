---
name: bucks-copy-macos-structure
description: >
  Use for BucksCopy macOS SwiftUI structure, module placement, Tuist/Xcode target
  questions, app composition, and file location decisions across App,
  Presentation, Domains, and Data.
---

# BucksCopy macOS Structure

## 읽기 순서

1. `AGENTS.md`
2. `docs/20-architecture/system-overview.md`
3. `README.md` when commands or project defaults matter

## 배치 판단

| 질문 | 위치 |
| --- | --- |
| 앱 시작, menu/window, composition root | `App` |
| credential UI, bot status UI, strategy settings UI, reusable SwiftUI component | `Presentation` |
| candle, strategy, order, risk contract | `Domains` |
| Bitget DTO/router/repository 구현 | `Data` |
| market stream, candle backfill, candle builder orchestration | `Data` with Domain contracts |
| Keychain, URLSession/WebSocket, SQLite local store, clock | `Data` adapters |
| logging, decimal/money, DI, error normalize | smallest fitting layer, usually `Domains` for pure types or `Data` for adapters |

## 출력 규칙

- 실제 경로 또는 목표 레이어를 함께 제시한다.
- credential, Bitget private API, live trading이 닿으면 Security route를 제안한다.
- 구조 정책 변경이면 `decision-log.md` 갱신 필요성을 언급한다.
