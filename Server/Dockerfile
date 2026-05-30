FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir cryptography==42.0.8

WORKDIR /app
COPY Server/PaperRunnerPython/paper_runner.py /app/paper_runner.py
RUN mkdir -p /var/lib/bucks-copy /var/log/bucks-copy

ENV BUCKS_COPY_DATA_DIR=/var/lib/bucks-copy
ENV BUCKS_COPY_SYMBOLS=BTCUSDT,ETHUSDT
ENV BUCKS_COPY_CANDLE_LIMIT=150000
ENV BUCKS_COPY_FETCH_CANDLE_LIMIT=1000
ENV BUCKS_COPY_HISTORY_BACKFILL_PAGES_PER_CYCLE=800
ENV BUCKS_COPY_POLL_SECONDS=30
ENV BUCKS_COPY_LIVE_ORDER_EXECUTION_ENABLED=false
ENV BUCKS_COPY_LIVE_ORDER_MARGIN_USDT=0
ENV BUCKS_COPY_API_HOST=0.0.0.0
ENV BUCKS_COPY_API_PORT=8787
ENV TZ=Asia/Seoul

EXPOSE 8787

CMD ["python", "-u", "/app/paper_runner.py"]
