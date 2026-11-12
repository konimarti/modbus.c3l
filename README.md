# modbus.c3l

Modbus library for C3: a sans-IO protocol core (PDU codec, MBAP and RTU framing, client and server state machines,
register/value helpers), a blocking TCP adapter, and the command line tool `mbtool`.

Scope: Modbus Application Protocol v1.1b3 and Modbus Messaging on TCP/IP v1.0b; function codes 1, 2, 3, 4, 5, 6, 15, 16,
22, 23, 8 (sub-function 0), 17 and 43/14 (device identification).

## Install

```
c3l add modbus
c3l sync
```

## Example

```c3
import std::io, std::time;
import modbus, modbus::client, modbus::pdu, modbus::tcp, modbus::transport, modbus::data;

fn void? read_temperature()
{
	TcpTransport t;
	t.connect("192.168.1.10", 502, time::sec(2))!;
	defer (void)t.close();
	BlockingClient bc;
	bc.init((Transport)&t, client::default_config(), mem)!;
	defer bc.free();
	Request req = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 100, 2);
	ExceptionCode exc;
	Response rsp = bc.call(&req, &exc)!;      // REMOTE_EXCEPTION: the device answered with an exception (code in exc)
	ushort[2] regs;
	rsp.copy_regs(&regs)!;
	io::printfn("%g", data::get_f32(&regs, 0, CDAB)!);
}
```

## Layout

| module | what |
|---|---|
| `modbus` | function codes, exception codes, limits, faults, and the small shared helpers `ClockFn`/`real_clock` (the monotonic clock the adapters read) and `is_timeout` (matches another library's `TIMEOUT` fault by name) |
| `modbus::pdu` | request and response codec for every function above, device-id object iterator |
| `modbus::frame` | MBAP framer, CRC-16, RTU frames |
| `modbus::data` | registers to int16/32/64, float32/64, strings in all four byte/word orders; coil packing |
| `modbus::client` | sans-IO client: pipelining by transaction id, timeouts (time is passed in), write guard |
| `modbus::server` | sans-IO server: `DataModel` callbacks, `RegisterMap`, RTU entry point `handle_rtu` |
| `modbus::transport` | `interface Transport` (`read`, `write`, `close`, with `Duration` timeouts), shared shape of the plant libraries |
| `modbus::rtu_stream` | RTU over any `Transport`: frames by silence (`RtuStream`), `RtuClient`, `serve_rtu_once`; serial I/O itself is not part of the library |
| `modbus::tcp` | `TcpTransport`, `BlockingClient`, `TcpServer` (poll based, no threads) |

The sans-IO core never reads a clock and does no I/O: bytes in, events and bytes out. Any type with the three
`Transport` methods can be passed through an explicit cast, for example a TLS transport.

## Writes are explicit

Writing to a machine needs two steps: the library refuses every write function unless `ClientConfig.allow_write` is set
(`WRITE_NOT_ALLOWED`, nothing is sent), and `mbtool write` needs `--allow-write`.

## mbtool

```
mbtool read  HOST[:PORT] [--unit N] [--fc coils|discrete|holding|input] [--addr A] [--count C] [--as f32] [--order CDAB]
mbtool write HOST[:PORT] --allow-write [--unit N] [--fc coil|register|coils|registers] [--addr A] VALUE...
mbtool serve [--bind ADDR] [--port P] [--unit N] [--coils N] [--registers N] [--allow-write]
mbtool devid HOST[:PORT] [--code 1|2|3]
```

Exit codes: 0 ok, 1 error or timeout, 2 usage error or refused write, 3 Modbus exception. `mbtool serve` binds
127.0.0.1 unless `--bind` is given and is read-only without `--allow-write`. `tools/smoke.sh` and `tools/cli-test.sh`
run the tool against its own server.

## RTU

`RtuStream` frames a byte stream by silence: a frame ends when no byte arrives for the gap you pass in (3.5 character
times on a serial line, 5 to 20 ms for RTU over a TCP gateway). `RtuClient` sends one request at a time and flushes
stale input and waits the gap before it sends, so a late answer to an earlier request is not taken for the next one;
an answer that arrives after that quiet time cannot be told apart from a real one (inherent to RTU). A frame with a
bad CRC is dropped and the request times out. `serve_rtu_once` serves one frame; broadcasts (address 0) are executed
and never answered. `tools/peer/run.sh --rtu` runs the pymodbus suite with RTU framing over TCP.

## Server limits

`TcpServer` serves up to 8 connections at a time with non-blocking sockets. A connection whose answers are not taken for
`write_timeout` (default 5 s; the timer restarts whenever its answers have been written out completely; zero
switches it off) is dropped, and so is a connection that is silent for
`idle_timeout` (default 60 s, zero switches it off) or that leaves a request unfinished for `read_timeout` (default 10 s). A full server turns new clients away until a slot is free.

## Things to know about real devices

- Addresses are 0-based protocol addresses. Vendor documents often use 1-based numbers or 4xxxx/3xxxx references:
  subtract the offset yourself.
- Many devices and gateways answer slowly; raise `--timeout` (or `ClientConfig.timeout`) for gateways.
- Some devices cap reads below 125 registers. The library rejects larger requests per the specification, the caller
  chunks (`mbtool read` splits long reads at the specification limits only).
- `--unit` defaults to 1. Many directly connected devices ignore the unit id or expect 0xFF; some gateways use it for
  routing. A device that answers with another unit id needs `ClientConfig.check_unit = false`.
- Word order of 32 and 64 bit values differs between vendors: try ABCD, CDAB, BADC and DCBA.

## Tests

`c3c test` runs the unit tests (hex fixtures from the specification examples, loopback tests, fuzz-style tests with
seeded random input). They need no network peer; the TCP tests use 127.0.0.1 with a free port.

## Versioning

The version lives in `project.json` and in `modbus::VERSION` (`modbus.c3`); bump both with
`c3c compile-run tools/bump_version.c3 -- 0.2.0` from the repository root (a test checks that they match).

## Part of the C3 plant automation libraries

Pure C3 building blocks for plant data infrastructure: read PLCs over S7, Modbus and OPC UA, move the
data over MQTT, and protect it with TLS. Each library works on its own; together they form the base for
an edge gateway.

- [mqtt.c3l](https://github.com/konimarti/mqtt.c3l): MQTT 3.1.1 and 5.0 client (sans-IO core, blocking client, `mqttc`)
- **modbus.c3l** (this library): Modbus TCP and RTU client and server (`mbtool`)
- [s7.c3l](https://github.com/konimarti/s7.c3l): Siemens S7comm client for S7-300/400/1200/1500 (`s7tool`)
- [opcua.c3l](https://github.com/konimarti/opcua.c3l): OPC UA binary client with generated types (`uatool`)
- [tls.c3l](https://github.com/konimarti/tls.c3l): TLS 1.2/1.3 transport on OpenSSL 3 with certificate and hostname checks (`tlsc`)

Licence: MIT.
