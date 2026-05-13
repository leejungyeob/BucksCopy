# Token Optimization Playbook

## 한글 요약

- 하네스 변경은 fixture 기반 검증으로 유지합니다.
- direct-handle 대상은 worker 생성 금지, route 조건 충족 시에만 specialist를 사용합니다.
- `.codex/runs/**`는 로컬 실행 기록이며 기본적으로 커밋하지 않습니다.

## Harness Checks

```bash
python3 scripts/ci/check_agent_config.py
python3 scripts/ci/check_agent_routing.py
python3 scripts/ci/check_agent_trace.py
python3 scripts/ci/write_agent_trace.py \
  --task-id 2026-05-13-sample \
  --request-summary "Answer a structure question." \
  --direct-handle \
  --used-skill bucks-copy-macos-structure
```

## Fixture 기준

| fixture | 목적 |
| --- | --- |
| `scripts/ci/fixtures/agent-routing/*.json` | 요청 prompt가 기대 route로 분류되는지 확인 |
| `scripts/ci/fixtures/agent-trace/*.json` | trace JSON 필수 필드와 agent/skill 이름 검증 |

## 운영 규칙

- `max_threads = 3`, `max_depth = 1`을 기본으로 둡니다.
- Bitget/auth/order/live 관련 작업은 보수적으로 specialist route를 사용합니다.
- skill body는 짧게 유지하고, 세부 도메인 정책은 canonical docs를 참조합니다.
- route fixture가 실패하면 docs와 스크립트 중 무엇이 canonical인지 먼저 판단하고 한쪽만 임시로 맞추지 않습니다.
