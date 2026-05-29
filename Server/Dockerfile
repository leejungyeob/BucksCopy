FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Server/PaperRunnerPython/paper_runner.py /app/paper_runner.py
RUN mkdir -p /var/lib/bucks-copy /var/log/bucks-copy

ENV BUCKS_COPY_DATA_DIR=/var/lib/bucks-copy
ENV BUCKS_COPY_SYMBOLS=BTCUSDT,ETHUSDT
ENV BUCKS_COPY_CANDLE_LIMIT=500
ENV BUCKS_COPY_POLL_SECONDS=30
ENV TZ=Asia/Seoul

CMD ["python", "-u", "/app/paper_runner.py"]
