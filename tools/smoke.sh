#!/bin/sh
# Smoke test without any peer: serve a register map, write two registers, read them back.
# usage: tools/smoke.sh [path/to/mbtool]
set -eu
MBTOOL=${1:-build/mbtool}
PORT=${MBTOOL_SMOKE_PORT:-5020}
LOG=$(mktemp)
"$MBTOOL" serve --port "$PORT" --allow-write >"$LOG" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true; rm -f "$LOG"' EXIT INT TERM

# wait until the server reports that it listens
i=0
until grep -q '^listening' "$LOG"; do
	i=$((i + 1))
	if [ "$i" -gt 50 ]; then
		echo "smoke: the server did not start" >&2
		cat "$LOG" >&2
		exit 1
	fi
	sleep 0.1
done

"$MBTOOL" write 127.0.0.1:"$PORT" --fc registers --addr 0 --allow-write 10 20 >/dev/null
OUT=$("$MBTOOL" read 127.0.0.1:"$PORT" --fc holding --addr 0 --count 2)
echo "read: $OUT"
[ "$OUT" = "10 20" ]
