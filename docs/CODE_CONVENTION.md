# Code Convention

## 한글 요약

- SwiftUI/macOS 코드는 명확한 타입, 작은 책임, 테스트 가능한 의존성 주입을 우선합니다.
- 자동매매 도메인은 숫자/시간/상태 전이가 중요하므로 암시적 변환과 ad-hoc 문자열 처리를 피합니다.
- formatter는 요청 없이 대규모로 실행하지 않습니다.

## Swift 기본

| 항목 | 규칙 |
| --- | --- |
| 타입 | `UpperCamelCase` |
| 변수/함수 | `lowerCamelCase` |
| class | 상속 의도가 없으면 `final` 우선 |
| async | 새 비동기 API는 Swift Concurrency 우선 |
| Decimal | 가격/수량/잔고는 `Double`보다 decimal-safe 타입 우선 |
| Date | candle bucket 계산은 명시 timezone/epoch 기준으로 처리 |

## import

- Apple 프레임워크, 내부 모듈, 서드파티 순서로 둡니다.
- 내부 모듈은 필요 시 `App / Presentation / Domains / Data` 순서로 그룹화합니다.
- `@_exported import`는 사용하지 않습니다.

## 보안 코드

- credential 값은 `String(describing:)`, `debugPrint`, `dump` 대상이 되지 않게 합니다.
- signature 생성 함수는 테스트 fixture로 검증하되 실제 secret을 쓰지 않습니다.
- 로그에는 redacted identifier와 error category만 남깁니다.

## Git 관례

- 브랜치 prefix는 기본적으로 `codex/`를 사용합니다.
- 커밋 메시지는 가능하면 한글로 요약합니다.
