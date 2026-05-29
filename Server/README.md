# BucksCopy Server

## 한글 요약

- 현재 서버 단계는 실거래가 아니라 `paper-runner`입니다.
- runner는 Bitget public REST로 `15m` candle만 받아 JSON 파일에 저장하고, closed candle 기준으로 전략을 평가합니다.
- Bitget API key, secret, passphrase는 아직 이 서버 배포에 넣지 않습니다.

## Paper Runner

Local one-shot check:

```bash
BUCKS_COPY_DATA_DIR=.server-data \
BUCKS_COPY_RUN_ONCE=true \
python3 Server/PaperRunnerPython/paper_runner.py
```

Docker one-shot check:

```bash
docker build -f Server/Dockerfile -t bucks-copy-paper-runner .
docker run --rm \
  -e BUCKS_COPY_RUN_ONCE=true \
  -v "$PWD/.server-data:/var/lib/bucks-copy" \
  bucks-copy-paper-runner
```

Server compose run from the repository root:

```bash
cp Server/env.paper.example .env
docker compose -f Server/docker-compose.paper.yml up -d --build
docker compose -f Server/docker-compose.paper.yml logs -f
```

If the mounted data/log folders were created by an earlier container attempt
with restrictive permissions, reset ownership once:

```bash
sudo chown -R ubuntu:ubuntu ~/bucks-copy-server/data ~/bucks-copy-server/logs
chmod -R u+rwX ~/bucks-copy-server/data ~/bucks-copy-server/logs
```

The runner writes JSON/JSONL files under `BUCKS_COPY_DATA_DIR`:

- `candles-{symbol}-15m.json`: normalized Bitget public OHLCV candles
- `trade-event-logs.jsonl`: paper signal and heartbeat records
- `paper-runner-status.json`: latest runner status for the future API/UI
- `paper-runner-evaluations.jsonl`: duplicate evaluation guard by `symbol/timeframe/strategy/openTime`

## Safety Boundary

- No private Bitget REST calls.
- No WebSocket private login.
- No order placement.
- No credential storage.
- No live execution until a separate explicit server-side consent and protection-order flow is implemented.
