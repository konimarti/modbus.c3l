module modbus::transport;

import std::time;
import modbus;

// Byte stream under a Modbus connection. Same method shape in all plant libraries (mqtt, s7, opcua, modbus), so one
// type (TcpTransport, tls.c3l's TlsTransport, a test double) can be passed through an explicit interface cast:
//
//     TlsTransport tls = ...;
//     Transport t = (Transport)&tls;
//
// TIMEOUT and CLOSED are this library's faults (same names in every library). A transport type does not need to
// import modbus: three @dynamic methods of exactly this shape are enough.
interface Transport
{
	// 1..buf.len bytes; faults: TIMEOUT (nothing arrived in time), CLOSED (peer EOF or error).
	// Bytes the transport already holds are returned before it waits.
	fn usz? read(char[] buf, Duration timeout);
	// Writes all of data or faults (TIMEOUT, CLOSED).
	fn void? write(char[] data, Duration timeout);
	// Idempotent.
	fn void? close();
}
