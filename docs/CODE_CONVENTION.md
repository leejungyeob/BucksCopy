# Code Convention

## 한글 요약

- 현재 활성 코드는 Python server runner 기준입니다.
- 자동매매 도메인은 숫자/시간/상태 전이가 중요하므로 암시적 변환과 ad-hoc 문자열 처리를 피합니다.
- formatter는 요청 없이 대규모로 실행하지 않습니다.

## Python 기본

| 항목 | 규칙 |
| --- | --- |
| 가격/수량/잔고 | `Decimal` 우선 |
| 시간 | UTC epoch/ISO를 명시적으로 변환 |
| 전략 판단 | `paper_runner.evaluate_strategy(...)`를 단일 기준으로 사용 |
| 테스트 | fixture 기반 deterministic regression 우선 |
| 로그 | secret, signature payload, raw private response 출력 금지 |

## 보안 코드

- credential 값은 `print`, exception text, JSON log 대상이 되지 않게 합니다.
- signature 생성 함수는 테스트 fixture로 검증하되 실제 secret을 쓰지 않습니다.
- 로그에는 redacted identifier와 error category만 남깁니다.

## Git 관례

- 브랜치 prefix는 기본적으로 `codex/`를 사용합니다.
- 커밋 메시지는 가능하면 한글로 요약합니다.
