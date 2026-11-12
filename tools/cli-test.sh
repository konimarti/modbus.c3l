#!/bin/sh
# Exit codes and output of mbtool against its own server (no peer needed).
# usage: tools/cli-test.sh [path/to/mbtool]
MBTOOL=${1:-build/mbtool}
PORT=${MBTOOL_CLI_PORT:-5021}
RO_PORT=$((PORT + 1))
FAILED=0
LOGS=$(mktemp -d)
"$MBTOOL" serve --port "$PORT" --allow-write >"$LOGS/rw.log" 2>&1 &
RW=$!
"$MBTOOL" serve --port "$RO_PORT" >"$LOGS/ro.log" 2>&1 &
RO=$!
trap 'kill "$RW" "$RO" 2>/dev/null; rm -rf "$LOGS"' EXIT INT TERM
for log in "$LOGS/rw.log" "$LOGS/ro.log"; do
	i=0
	until grep -q '^listening' "$log"; do
		i=$((i + 1))
		[ "$i" -gt 50 ] && { echo "server did not start"; exit 1; }
		sleep 0.1
	done
done

# check NAME EXPECTED_EXIT EXPECTED_STDOUT COMMAND...
check() {
	name=$1; want_rc=$2; want_out=$3; shift 3
	out=$("$@" 2>"$LOGS/err")
	rc=$?
	if [ "$rc" != "$want_rc" ] || [ "$out" != "$want_out" ]; then
		echo "FAIL $name: exit $rc (want $want_rc), output '$out' (want '$want_out')"
		sed 's/^/    stderr: /' "$LOGS/err"
		FAILED=1
	else
		echo "ok   $name"
	fi
}

H=127.0.0.1:$PORT
R=127.0.0.1:$RO_PORT
check "help" 0 "" sh -c "$MBTOOL -h | head -1 | grep -q '^usage' && true"
check "refused write" 2 "" "$MBTOOL" write "$H" --addr 0 5
check "write registers" 0 "ok" "$MBTOOL" write "$H" --fc registers --addr 10 --allow-write 1 2 3
check "read registers" 0 "1 2 3" "$MBTOOL" read "$H" --addr 10 --count 3
check "write coils" 0 "ok" "$MBTOOL" write "$H" --fc coils --addr 4 --allow-write 1 0 1 1
check "read coils" 0 "1 0 1 1" "$MBTOOL" read "$H" --fc coils --addr 4 --count 4
check "write coil" 0 "ok" "$MBTOOL" write "$H" --fc coil --addr 0 --allow-write 1
check "read coil" 0 "1" "$MBTOOL" read "$H" --fc coils --count 1
check "float word orders" 0 "1 1" sh -c "$MBTOOL write $H --fc registers --addr 20 --allow-write 0x3F80 0 0 0x3F80 >/dev/null && echo \"\$($MBTOOL read $H --addr 20 --count 2 --as f32 --order ABCD | cut -d' ' -f1) \$($MBTOOL read $H --addr 22 --count 2 --as f32 --order CDAB)\""
check "u32" 0 "65538" "$MBTOOL" read "$H" --addr 10 --count 2 --as u32 --order ABCD
check "negative register" 0 "-2" sh -c "$MBTOOL write $H --fc register --addr 30 --allow-write -2 >/dev/null && $MBTOOL read $H --addr 30 --as i16"
check "long read is split" 0 "ok" sh -c "$MBTOOL read $H --addr 0 --count 300 | wc -w | grep -qx 300 && echo ok"
check "unmapped address" 3 "" "$MBTOOL" read "$H" --addr 5000
check "read-only server" 3 "" "$MBTOOL" write "$R" --addr 0 --allow-write 5
check "read-only server reads" 0 "0" "$MBTOOL" read "$R" --addr 0
check "device id" 0 "0: mbtool
1: modbus.c3l
2: 0.1.0" "$MBTOOL" devid "$H"
check "unit filter" 0 "0" "$MBTOOL" read "$H" --unit 7 --addr 99
check "no server" 1 "" "$MBTOOL" read 127.0.0.1:1 --addr 0 --timeout 300
check "bad option" 2 "" "$MBTOOL" read "$H" --bogus 1
check "bad count" 2 "" "$MBTOOL" read "$H" --count 0
check "bad type" 2 "" "$MBTOOL" read "$H" --as f16
check "bad order" 2 "" "$MBTOOL" read "$H" --as u32 --order XXXX
check "bad coil value" 2 "" "$MBTOOL" write "$H" --fc coil --addr 0 --allow-write 2
check "unknown command" 2 "" "$MBTOOL" frobnicate
[ "$FAILED" = 0 ] && echo "all ok"
exit "$FAILED"
