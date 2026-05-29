---
name: bucks-copy-l2-security
description: >
  Use when BucksCopy work touches Bitget credentials, API key/secret/passphrase,
  Keychain, REST/WebSocket signatures, private channels, order/account data,
  logging, storage, URL handling, or live-trading safety.
---

# BucksCopy L2 Security

## 먼저 읽기

1. `AGENTS.md`
2. `docs/30-quality/security-checklist.md`
3. 관련 auth/storage/network/order 코드
4. `docs/20-architecture/system-overview.md` when boundaries are involved

## Focus Areas

- Secrets and credential storage.
- Signature construction and logging.
- Keychain lifecycle.
- WebSocket private channel login.
- Live execution consent, protection, and fail-closed boundary.

## Output

- 위험 수준
- 발견 사항
- 왜 위험한지
- 수정 권장 방향
- 다음 검증
