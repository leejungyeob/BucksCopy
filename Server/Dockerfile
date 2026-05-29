FROM swift:6.0-noble AS build

WORKDIR /src
COPY Package.swift ./
COPY Sources ./Sources
COPY Server ./Server
RUN swift build -c release --product BucksCopyPaperRunner

FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 10001 bucks
RUN mkdir -p /var/lib/bucks-copy /var/log/bucks-copy \
    && chown -R bucks:bucks /var/lib/bucks-copy /var/log/bucks-copy

COPY --from=build /src/.build/release/BucksCopyPaperRunner /usr/local/bin/BucksCopyPaperRunner

USER bucks
WORKDIR /home/bucks

ENV BUCKS_COPY_DATA_DIR=/var/lib/bucks-copy
ENV BUCKS_COPY_SYMBOLS=BTCUSDT,ETHUSDT
ENV BUCKS_COPY_CANDLE_LIMIT=500
ENV BUCKS_COPY_POLL_SECONDS=30
ENV TZ=Asia/Seoul

CMD ["BucksCopyPaperRunner"]
