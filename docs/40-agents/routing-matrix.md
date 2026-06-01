# Routing Matrix

## 한글 요약

- 이 문서는 요청 유형별 기본 route를 정합니다.
- direct-handle 가능 작업은 specialist를 붙이지 않습니다.
- 위험이 늘어나면 L1이 route를 다시 조정합니다.

## 기본 라우팅 표

| 요청 유형 | 기본 경로 | direct-handle | 완료 기준 |
| --- | --- | --- | --- |
| 단순 질의응답 | 메인 에이전트 | 가능 | 답변으로 종료 |
| 짧은 문서/오타 | 메인 에이전트 | 가능 | 좁은 diff + 최소 확인 |
| server runner 구조/파일 위치 | `bucks-copy-trading-engine` | 가능 | 경로와 이유 제시 |
| Bitget REST/WS 연동 | L1 -> Architect -> Security -> TDD Guide -> Code Reviewer | 보통 비권장 | DTO/auth/reconnect/rate-limit/검증 반영 |
| USDT-M symbol catalog / Watchlist | L1 -> Architect -> Security -> TDD Guide -> Code Reviewer | 조건부 | 후보 필터 + Watchlist-only 구독/매매 검증 |
| API credential/storage | L1 -> Architect -> Security -> TDD Guide -> Code Reviewer | 비권장 | secret 저장/삭제/로그 검증 |
| candle/strategy/trading engine | L1 -> Architect -> TDD Guide -> Code Reviewer | 조건부 | deterministic acceptance + edge case |
| live execution policy | L1 -> Architect -> Security -> TDD Guide -> Doc Writer -> Code Reviewer | 비권장 | decision log + 보안/테스트 기준 |
| build/generate break | L1 -> Build Fixer -> Code Reviewer | 비권장 | build/generate 복구 |
| 구조 migration | L1 -> Architect -> Migration -> Build Fixer -> Code Reviewer -> Doc Writer | 비권장 | 경계 정합성 + 검증 + 문서 |
| canonical docs/skills/harness | L1 -> Doc Writer -> Code Reviewer | 조건부 | docs/skills/scripts 일치 + harness checks |

## 실행 owner 선택 규칙

- build 복구가 핵심이면 `bucks-copy-l3-build-fixer`
- 문서/스킬/하네스 정리가 핵심이면 `bucks-copy-l3-doc-writer`
- 레이어 이동이 핵심이면 `bucks-copy-l3-migration`
- 나머지 소규모 실행은 메인 에이전트가 직접 처리 가능
