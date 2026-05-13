# AGENTS.md

## 한글 요약

- 기본값: `최소 변경`, `보안 우선`, `비밀정보 출력 금지`, `Paper trading 우선`, `실거래 기본 차단`
- Bitget API key, secret, passphrase는 코드/문서/로그에 절대 남기지 않습니다.
- 자동매매 기능은 먼저 재현 가능한 candle/strategy/paper execution 검증을 통과해야 합니다.
- 복합 작업은 L1/L2/L3 라우팅을 사용하고, 작은 작업은 direct-handle을 우선합니다.
- 적용 범위: 저장소 전체

## Notion Blog Manual-Write Rule

- Do not automatically create Notion posts for solved troubleshooting issues.
- Create a Notion post only when the user explicitly asks to record, blog, or document the issue in Notion.
- Target data source when requested: `collection://306a85e3-c5ae-80c8-b1e5-000b8a88c2c3`.
- Style when requested: Korean Naver blog style, practical and readable.
- If a Notion post is created, return the created page link.

## 출력 규약

| 블록 | 규칙 |
| --- | --- |
| `결론` | 기본 필수 |
| `변경 요약` | 코드/문서 변경이 있을 때 포함 |
| `검증 방법 + 리스크/롤백` | 기본 필수 |

## 절대 규칙

| 항목 | 규칙 |
| --- | --- |
| 추측 | 근거 없으면 `확인 필요`와 확인 경로를 제시 |
| 변경 범위 | 요청 없으면 좁은 diff 우선 |
| 실거래 | v1 기본값은 Paper trading이며 live order는 명시 정책 전까지 구현/활성화 금지 |
| 거래 범위 | Bitget USDT-M Futures만 대상으로 하며 API 값은 `productType=USDT-FUTURES`로 고정 |
| Watchlist | 전체 USDT-M Futures catalog를 불러오되 구독/자동매매는 사용자가 선택한 Watchlist 심볼만 대상 |
| 심볼 후보 | `symbolStatus=normal`이고 `supportMarginCoins`에 `USDT`가 있는 심볼만 Watchlist 후보 |
| WebSocket 구독 | 한 연결당 50개 이하 채널을 기본 제한으로 두고 초과 시 분리 또는 validation 실패 |
| 비밀정보 | API key, secret, passphrase, 계정 정보, 주문 식별자 원문 출력/기록 금지 |
| 인증 저장 | 민감정보는 Keychain-facing Data adapter만 소유 |
| 시장 데이터 저장 | Watchlist closed candle은 로컬 DB에 누적하되 credential/raw private response는 저장 금지 |
| 로그 | 토큰, 서명 payload, credential, 주문 원문 응답 전체 dump 금지 |
| 외부 API | Bitget 공식 문서 기준으로 endpoint, signature, rate-limit, WebSocket ping/pong 확인 |
| 구조 | 기본 레이어는 `App / Presentation / Domains / Data`, 경계 위반은 예외가 아니라 debt |
| 문서 | canonical 중복 금지, 새 문서 전 기존 문서 흡수 가능성 확인 |
| formatter | 요청 없는 대규모 formatter 실행 금지 |
| 커밋 메시지 | 가능하면 한글 우선 |

## Direct Handle vs Orchestration

| 상황 | 기본 처리 |
| --- | --- |
| 단순 질의응답, 짧은 문서 수정, 1~3파일 저위험 수정 | 메인 에이전트 direct-handle |
| 여러 레이어/단계 동시 변경 | L1 기준 오케스트레이션 |
| Bitget REST/WS, auth, Keychain, order, storage, live/paper policy 포함 | Architect, Security, TDD Guide 포함 |
| candle aggregation, strategy engine, trading execution 변경 | Architect, TDD Guide, Code Reviewer 포함 |
| build/generate/target wiring 복구 | Build Fixer 포함 |
| canonical 문서/스킬 변경 | Doc Writer 포함 |

| 운영 원칙 | 규칙 |
| --- | --- |
| Layer 1 | `bucks-copy-l1-planner-orchestrator` |
| Layer 2 | 구조/리뷰/보안/테스트 판단 |
| Layer 3 | build 복구, 문서 갱신, migration 실행 |
| writer | 한 cycle당 write-capable owner 1명 |
| agent | 전체 fan-out 최대 3개, write-capable worker는 한 cycle당 1명 |
| handoff | `.codex/contracts/handoff-template.yaml` 기준 |

## Canonical Docs

| 문서 | 용도 |
| --- | --- |
| [README.md](README.md) | 사람용 진입 문서 |
| [docs/00-governance/doc-map.md](docs/00-governance/doc-map.md) | 문서 지도 |
| [docs/20-architecture/system-overview.md](docs/20-architecture/system-overview.md) | 구조/아키텍처 |
| [docs/20-architecture/decision-log.md](docs/20-architecture/decision-log.md) | 정책 결정 기록 |
| [docs/30-quality/test-strategy.md](docs/30-quality/test-strategy.md) | 테스트 전략 |
| [docs/30-quality/security-checklist.md](docs/30-quality/security-checklist.md) | 보안 체크리스트 |
| [docs/40-agents/orchestration-model.md](docs/40-agents/orchestration-model.md) | 에이전트 운영 모델 |
| [docs/40-agents/routing-matrix.md](docs/40-agents/routing-matrix.md) | 작업 라우팅 표 |
| [docs/40-agents/skill-catalog.md](docs/40-agents/skill-catalog.md) | 로컬 스킬 목록 |
| [docs/40-agents/token-optimization-playbook.md](docs/40-agents/token-optimization-playbook.md) | 토큰/하네스 운영 기준 |
| [docs/50-migration/migration-playbook.md](docs/50-migration/migration-playbook.md) | 마이그레이션 규약 |
| [docs/CODE_CONVENTION.md](docs/CODE_CONVENTION.md) | 코드 스타일 |

## Update Rule

- 구조/운영 정책 변경 시 `decision-log.md` 검토
- 테스트 기대치 변경 시 `test-strategy.md` 검토
- Bitget/auth/storage/order/logging 영향 변경 시 `security-checklist.md` 기준 리뷰
- 스킬 역할 변경 시 `skill-catalog.md`, 해당 `SKILL.md`, `skill-metadata.yaml`, `.codex/agents/*.toml` 동시 검토
