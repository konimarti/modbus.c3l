#!/usr/bin/env bash
# Interoperability run against pymodbus, both directions.
#   tools/peer/run.sh          Modbus TCP (MBAP) framing
#   tools/peer/run.sh --rtu    RTU framing over the TCP connection
# Prints SKIPPED and exits 0 when pymodbus is missing (MODBUS_PEER_PYTHON names the python to use).
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$DIR"

PYTHON="${MODBUS_PEER_PYTHON:-python3}"

if ! "$PYTHON" tools/peer/check_pymodbus.py 2>/dev/null; then
    echo "SKIPPED: pymodbus missing"
    exit 0
fi

RTU=""
SUFFIX=""
FEATURE=()
if [ "${1:-}" = "--rtu" ]; then
    RTU="--rtu"
    SUFFIX="_rtu"
    FEATURE=(-D RTU)
fi

mkdir -p build
c3c compile "${FEATURE[@]}" *.c3 tools/peer/peer_client.c3 -o "build/peer_client$SUFFIX" >/dev/null
c3c compile "${FEATURE[@]}" *.c3 tools/peer/peer_server.c3 -o "build/peer_server$SUFFIX" >/dev/null

PORT=5020

# 1. We are client: call server peer (pymodbus)
"$PYTHON" tools/peer/server.py --port "$PORT" $RTU >/dev/null 2>&1 &
PY_PID=$!
"$PYTHON" tools/peer/wait_port.py 127.0.0.1 "$PORT"
"./build/peer_client$SUFFIX" 127.0.0.1 "$PORT"
kill -9 "$PY_PID" 2>/dev/null || true
wait "$PY_PID" 2>/dev/null || true
"$PYTHON" tools/peer/wait_free.py 127.0.0.1 "$PORT"

# 2. We are server: pymodbus client calls us
"./build/peer_server$SUFFIX" 127.0.0.1 "$PORT" >/dev/null 2>&1 &
C3_PID=$!
"$PYTHON" tools/peer/wait_port.py 127.0.0.1 "$PORT"
"$PYTHON" tools/peer/client.py --port "$PORT" $RTU
kill -9 "$C3_PID" 2>/dev/null || true
wait "$C3_PID" 2>/dev/null || true
"$PYTHON" tools/peer/wait_free.py 127.0.0.1 "$PORT"

exit 0
