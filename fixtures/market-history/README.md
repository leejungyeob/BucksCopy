# Market History Snapshot

This directory stores a portable SQLite snapshot for local backtest and chart
work on another machine.

## Files

- `BucksCopyCandles.sqlite.gz`: compressed sanitized market-history snapshot.

## Included Tables

- `candles`
- `candle_history_sync`

## Excluded Tables

- `trade_event_logs`

The runtime app database can contain live-order and account-adjacent event
messages. Keep those logs out of Git snapshots unless they are explicitly
sanitized for a test fixture.

## Source

Generated from the local app database:

`/Users/goods99j/Library/Application Support/BucksCopy/BucksCopy.sqlite`

To use it locally, decompress the file first:

```sh
gunzip -k fixtures/market-history/BucksCopyCandles.sqlite.gz
```
