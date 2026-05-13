# Skill Catalog

## 한글 요약

- 최소 스킬만 활성화합니다.
- domain skill은 Bitget/macOS/trading-engine 판단을 빠르게 시작하기 위한 reference skill입니다.
- runtime sub-agent는 `.codex/agents/*.toml`에만 둡니다.

## Domain Skills

| 스킬 | 역할 | 언제 쓰는가 |
| --- | --- | --- |
| [bucks-copy-macos-structure](../../.codex/skills/bucks-copy-macos-structure/SKILL.md) | macOS 앱 구조와 파일 배치 | App/Presentation/Domains/Data 위치 판단 |
| [bucks-copy-bitget-integration](../../.codex/skills/bucks-copy-bitget-integration/SKILL.md) | Bitget REST/WS 연동 | endpoint, signature, WebSocket, DTO, rate-limit, reconnect |
| [bucks-copy-trading-engine](../../.codex/skills/bucks-copy-trading-engine/SKILL.md) | 자동매매 엔진 경계 | candle aggregation, strategy, paper execution, live safety |

## Agent-backed Skills

| 스킬 | 역할 | Runtime agent |
| --- | --- | --- |
| [bucks-copy-l1-planner-orchestrator](../../.codex/skills/bucks-copy-l1-planner-orchestrator/SKILL.md) | 작업 분해와 route 결정 | `bucks-copy-l1-planner-orchestrator` |
| [bucks-copy-l2-architect](../../.codex/skills/bucks-copy-l2-architect/SKILL.md) | 구조 적합성 판단 | `bucks-copy-l2-architect` |
| [bucks-copy-l2-security](../../.codex/skills/bucks-copy-l2-security/SKILL.md) | credential/storage/network/order 보안 점검 | `bucks-copy-l2-security` |
| [bucks-copy-l2-tdd-guide](../../.codex/skills/bucks-copy-l2-tdd-guide/SKILL.md) | acceptance/test 전략 | `bucks-copy-l2-tdd-guide` |
| [bucks-copy-l2-code-reviewer](../../.codex/skills/bucks-copy-l2-code-reviewer/SKILL.md) | findings-first 리뷰 | `bucks-copy-l2-code-reviewer` |
| [bucks-copy-l3-build-fixer](../../.codex/skills/bucks-copy-l3-build-fixer/SKILL.md) | build/generate 복구 | `bucks-copy-l3-build-fixer` |
| [bucks-copy-l3-doc-writer](../../.codex/skills/bucks-copy-l3-doc-writer/SKILL.md) | canonical 문서 갱신 | `bucks-copy-l3-doc-writer` |
| [bucks-copy-l3-migration](../../.codex/skills/bucks-copy-l3-migration/SKILL.md) | 단계적 구조 이전 | `bucks-copy-l3-migration` |

## 관리 규칙

- 스킬 추가/삭제/이름 변경 시 이 문서, `skill-metadata.yaml`, 관련 `.toml`, `scripts/ci/check_agent_config.py`, trace/routing fixture를 함께 갱신합니다.
- docs와 skill 내용이 어긋나면 canonical docs를 먼저 정리한 뒤 skill을 맞춥니다.
