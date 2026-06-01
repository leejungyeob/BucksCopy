# Test Strategy

## 한글 요약

- 현재 활성 검증 기준은 Python server runner입니다.
- 실거래 판단과 백테스트 판단은 모두 `paper_runner.evaluate_strategy(...)`를 기준으로 맞춥니다.
- Swift/macOS 테스트는 프로젝트에서 제거되었고, 새 회귀 검증은 Python 테스트로 추가합니다.

## 기본 기대치

| 작업 유형 | 기본 기대치 |
| --- | --- |
| server runner 변경 | `py_compile`, runner unit test, closed-candle-only evaluation 확인 |
| strategy 변경 | fixture 기반 deterministic backtest, active route 확인, risk-blocked 조건 확인 |
| backtest/graph 변경 | `paper_runner_backtest.py` 사용, 별도 진입 판단 로직 재구현 금지 |
| live execution 변경 | Bitget payload test, fill confirmation, protection retry, fail-closed, sanitized log 검증 |
| credential/auth 변경 | secret/passphrase/raw private response 미저장, bearer auth fail-closed 확인 |
| docs/harness 변경 | Codex agent config/routing/trace checks |

## Required Commands

```bash
python3 -m py_compile \
  Server/PaperRunnerPython/paper_runner.py \
  Server/PaperRunnerPython/paper_runner_backtest.py
```

```bash
python3 -m unittest \
  Server/PaperRunnerPython/test_paper_runner_backtest.py \
  Server/PaperRunnerPython/test_paper_runner_live_execution.py
```

## Acceptance Scenarios

- Server runner starts -> fetches Bitget `15m` candles -> stores normalized candles -> evaluates only closed candles.
- Same `symbol/timeframe/strategy/candle openTime` is seen twice -> duplicate live order is not generated.
- Active strategy fixture backtest -> same market snapshot produces the same final balance, MDD, and trade count every run.
- Strategy signal occurs while live order gate is blocked -> no Bitget order API call and a sanitized risk/error reason is logged.
- Strategy signal occurs while live gate and order switch are enabled -> set leverage -> market entry -> fill confirmation -> position verification -> TP1/TP2/SL protection.
- Protection registration retries are exhausted -> fresh position snapshot is checked -> open position is fail-closed by `close-positions`.
- Credential login succeeds -> server stores only encrypted credential when encryption key exists, never raw secret/passphrase logs.

## Minimum Safety Set

1. Active strategy changes require fixture regression coverage.
2. Backtest tools must import the runtime strategy evaluator instead of copying strategy rules.
3. Live order path changes require gate, payload, protection, fail-closed, and log assertions.
4. Generated reports under `Derived/Reports` are artifacts, not canonical strategy truth.
