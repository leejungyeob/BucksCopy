# Orchestration Model

## 한글 요약

- 작은 작업은 direct-handle, 복합/고위험 작업은 L1/L2/L3 route를 사용합니다.
- Layer 2는 판단과 리뷰, Layer 3는 실행 역할입니다.
- 한 cycle당 write-capable owner는 하나만 둡니다.

## 런타임 구성

| 구분 | 경로 |
| --- | --- |
| repo 규칙 | `AGENTS.md` |
| 역할 문서 | `docs/40-agents/*` |
| skill 정의 | `.codex/skills/*/SKILL.md` |
| skill 메타데이터 | `.codex/skills/*/skill-metadata.yaml` |
| runtime agent | `.codex/agents/*.toml` |
| 실행 기본값 | `.codex/config.toml` |
| trace | `.codex/runs/YYYY-MM-DD/*.json` |

## 실행 기본값

| 항목 | 값 |
| --- | --- |
| `max_threads` | `3` |
| `max_depth` | `1` |
| `job_max_runtime_seconds` | `300` |

## Layer 정의

| Layer | 역할 | 구성 |
| --- | --- | --- |
| Layer 1 | 요구사항 분해, route, scope control, handoff, 통합 | `bucks-copy-l1-planner-orchestrator` |
| Layer 2 | 구조/보안/테스트/리뷰 판단 | Architect, Security, TDD Guide, Code Reviewer |
| Layer 3 | build 복구, 문서 갱신, migration 실행 | Build Fixer, Doc Writer, Migration |

## 오케스트레이션 활성화 조건

- Bitget REST/WS, auth, credential, Keychain, order, storage, logging을 건드림
- candle aggregation, strategy, trading engine, paper/live execution을 건드림
- 여러 레이어가 동시에 바뀜
- build/generate/target wiring 복구가 필요함
- canonical docs, skill, agent, CI harness가 바뀜

## Single-writer 규칙

1. 한 cycle에는 write-capable owner를 하나만 둡니다.
2. Layer 2는 read-only 분석자로 사용합니다.
3. 병렬 분석은 가능하지만 같은 파일군을 동시에 수정하지 않습니다.
4. 구조나 보안 판단이 흔들리면 실행 전에 L1으로 되돌립니다.
