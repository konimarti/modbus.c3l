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
| `modbus` | function codes, exception codes, limits, faults |
| `modbus::pdu` | request and response codec for every function above, device-id object iterator |
| `modbus::frame` | MBAP framer, CRC-16, RTU frames |
| `modbus::data` | registers to int16/32/64, float32/64, strings in all four byte/word orders; coil packing |
| `modbus::client` | sans-IO client: pipelining by transaction id, timeouts (time is passed in), write guard |
| `modbus::server` | sans-IO server: `DataModel` callbacks, `RegisterMap`, RTU entry point `handle_rtu` |
| `modbus::transport` | `interface Transport` (`read`, `write`, `close`, with `Duration` timeouts), shared shape of the plant libraries |
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
mbtool devid HOST[:PORT]
```

Exit codes: 0 ok, 1 error or timeout, 2 usage error or refused write, 3 Modbus exception. `mbtool serve` binds
127.0.0.1 unless `--bind` is given and is read-only without `--allow-write`. `tools/smoke.sh` and `tools/cli-test.sh`
run the tool against its own server.

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

Licence: MIT.
