# Migration Playbook

## 한글 요약

- 큰 리셋 대신 작은 slice 단위로 옮기고 매 단계에서 검증합니다.
- 구조 위반은 예외가 아니라 debt입니다.
- live trading 관련 migration은 별도 decision log와 보안 리뷰 전에는 진행하지 않습니다.

## 언제 쓰는가

- App 내부 구현을 Presentation/Domain/Data 경계로 이동할 때
- Bitget 연동 코드를 raw adapter와 repository로 분리할 때
- USDT-M Futures symbol catalog와 Watchlist 책임을 Presentation/Domain/Data로 분리할 때
- candle/strategy/trading execution을 테스트 가능한 Domain/Data 경계로 분리할 때
- local market history 저장소와 startup gap fill을 Data adapter 뒤로 숨길 때
- Tuist target wiring 또는 module boundary를 정리할 때

## 기본 절차

1. 현재 코드의 위치와 책임을 분류합니다.
2. Architect 관점으로 목표 경계를 확인합니다.
3. 한 번에 한 slice만 이동합니다.
4. touch한 slice 안의 금지 의존 관계를 제거합니다.
5. 관련 build/generate/check를 실행합니다.
6. 문서와 skill 영향이 있으면 같은 변경에서 정리합니다.

## 완료 조건

- 목표 경계가 `system-overview.md`와 일치함
- credential, Bitget DTO, trading execution 책임이 올바른 레이어에 있음
- Watchlist-only subscription/trading 원칙이 유지됨
- paper/live boundary가 흐려지지 않음
- 필요한 harness checks 또는 build checks가 실행됨
- canonical docs가 최신 상태임
