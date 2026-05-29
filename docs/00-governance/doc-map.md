# Document Map

## 한글 요약

- 이 문서는 `BucksCopy`의 canonical 문서 지도를 정의합니다.
- 문서는 사람과 Codex가 같이 보는 정본만 유지합니다.
- 새 문서를 만들기 전에 기존 canonical 문서에 흡수 가능한지 먼저 확인합니다.

## 문서 관리 원칙

1. 루트 `README.md`, `AGENTS.md`, `docs/`, `.codex/contracts`를 canonical set으로 둡니다.
2. 구조나 정책이 바뀌면 코드와 함께 문서 변경 여부를 검토합니다.
3. 대체된 운영 문서는 archive로 남기지 않고 같은 변경에서 정리합니다.
4. Bitget API 정책은 공식 문서 링크와 함께 최신성을 확인합니다.

## Canonical Set

| 문서 | 목적 | 갱신 트리거 |
| --- | --- | --- |
| [README.md](../../README.md) | 저장소 진입점, 기본 결정, 실행/검증 명령 | 구조/스택/검증 진입점 변경 |
| [AGENTS.md](../../AGENTS.md) | repo-wide 작업 규칙 | 작업 규칙, 출력 규약, 라우팅 기준 변경 |
| [docs/CODE_CONVENTION.md](../CODE_CONVENTION.md) | 코드 스타일과 Git 관례 | Swift/macOS 스타일 기준 변경 |
| [docs/20-architecture/system-overview.md](../20-architecture/system-overview.md) | 레이어와 책임 경계 | 구조 경계, target 구성, 의존 방향 변경 |
| [docs/20-architecture/decision-log.md](../20-architecture/decision-log.md) | ADR-lite 결정 기록 | repo-wide 구조/정책 결정 |
| [docs/30-quality/test-strategy.md](../30-quality/test-strategy.md) | 테스트/acceptance 기준 | 테스트 기대치 변경 |
| [docs/30-quality/security-checklist.md](../30-quality/security-checklist.md) | Bitget credential, storage, logging, trust boundary 점검 | auth/storage/order/network 정책 변경 |
| [docs/40-agents/orchestration-model.md](../40-agents/orchestration-model.md) | L1/L2/L3 운영 모델 | 에이전트 운영 정책 변경 |
| [docs/40-agents/routing-matrix.md](../40-agents/routing-matrix.md) | 요청 유형별 라우팅 | 라우팅 조건 변경 |
| [docs/40-agents/skill-catalog.md](../40-agents/skill-catalog.md) | 로컬 스킬 카탈로그 | 스킬 추가/삭제/역할 변경 |
| [docs/40-agents/token-optimization-playbook.md](../40-agents/token-optimization-playbook.md) | 하네스/토큰 운영 기준 | 검증 스크립트, fixture, trace 규칙 변경 |
| [docs/50-migration/migration-playbook.md](../50-migration/migration-playbook.md) | 단계적 구조 이전 | migration 절차/검증 변경 |
| [docs/50-migration/aws-lightsail-runner-workflow.html](../50-migration/aws-lightsail-runner-workflow.html) | AWS Lightsail server runner 전환 절차와 리스크 지도 | server runner 운영 전환 계획 변경 |
| [.codex/contracts/handoff-template.yaml](../../.codex/contracts/handoff-template.yaml) | 위임 handoff 계약 | 필수 handoff 필드 변경 |
| [.codex/contracts/run-trace-template.json](../../.codex/contracts/run-trace-template.json) | 실행 trace 형식 | trace 필드 변경 |
