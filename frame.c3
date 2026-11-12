module modbus::frame;

import std::core::mem;
import modbus;

// ---- MBAP (Modbus Messaging on TCP/IP, 3.1): tid(2) proto(2)=0 length(2) unit(1) pdu(length-1) ----

struct MbapHeader
{
	ushort tid;
	ushort proto;
	ushort length;       // unit id byte + PDU
	char unit;
}

struct MbapFrame
{
	MbapHeader header;
	char[] pdu;          // borrowed from the framer buffer
}

// pdu empty or longer than 253 bytes -> BAD_LENGTH
fn usz? mbap_encode(ushort tid, char unit, char[] pdu, char[] out)
{
	if (pdu.len == 0 || pdu.len > modbus::MAX_PDU) return modbus::BAD_LENGTH~;
	usz total = modbus::MBAP_LEN + pdu.len;
	if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
	ushort length = (ushort)(pdu.len + 1);
	out[0] = (char)(tid >> 8);
	out[1] = (char)(tid & 0xFF);
	out[2] = 0;
	out[3] = 0;
	out[4] = (char)(length >> 8);
	out[5] = (char)(length & 0xFF);
	out[6] = unit;
	mem::copy(&out[modbus::MBAP_LEN], pdu.ptr, (sz)pdu.len);
	return total;
}

// Stream reassembly: bytes in, whole frames out. Fixed storage, no allocation.
// Unconsumed bytes are buf[start:len]. next() only advances `start`; the buffer is compacted lazily at the
// start of the following feed()/next(), so the pdu slice of the last returned frame stays valid until then.
struct MbapFramer
{
	char[2 * modbus::MAX_TCP_ADU] buf;
	usz len;
	usz start;
}

fn void MbapFramer.compact(&self)
{
	if (self.start == 0) return;
	usz pending = self.len - self.start;
	if (pending > 0) mem::move(&self.buf[0], &self.buf[self.start], (sz)pending);
	self.start = 0;
	self.len = pending;
}

// Bytes taken but not yet returned as a frame.
fn usz MbapFramer.pending(&self)
{
	return self.len - self.start;
}

fn usz MbapFramer.free_space(&self)
{
	return self.buf.len - (self.len - self.start);
}

// Returns the number of bytes taken (less than data.len when the buffer is full).
fn usz MbapFramer.feed(&self, char[] data)
{
	self.compact();
	usz room = self.buf.len - self.len;
	usz n = data.len < room ? data.len : room;
	if (n > 0) mem::copy(&self.buf[self.len], data.ptr, (sz)n);
	self.len += n;
	return n;
}

// true: *out holds the next frame. false: more bytes are needed. A fault means the stream is broken:
// the connection must be closed (the same error is returned again until then).
fn bool? MbapFramer.next(&self, MbapFrame* out)
{
	self.compact();
	usz avail = self.len;
	if (avail >= 4 && (self.buf[2] != 0 || self.buf[3] != 0)) return modbus::BAD_PROTOCOL_ID~;
	if (avail < 6) return false;
	ushort length = (ushort)(((ushort)self.buf[4] << 8) | self.buf[5]);
	if (length < 2 || length > 254) return modbus::BAD_LENGTH~;
	usz total = 6 + (usz)length;
	if (avail < total) return false;
	out.header.tid = (ushort)(((ushort)self.buf[0] << 8) | self.buf[1]);
	out.header.proto = 0;
	out.header.length = length;
	out.header.unit = self.buf[6];
	out.pdu = self.buf[modbus::MBAP_LEN:total - modbus::MBAP_LEN];
	self.start = total;
	return true;
}

// ---- RTU (Modbus over Serial Line, 2.5 and 6.2.2): addr(1) pdu crc_lo crc_hi ----

// CRC-16/MODBUS: polynomial 0xA001 (reflected), initial value 0xFFFF; sent low byte first.
fn ushort crc16(char[] data)
{
	uint crc = 0xFFFF;
	foreach (b : data)
	{
		crc ^= b;
		for (int i = 0; i < 8; i++)
		{
			if (crc & 1)
			{
				crc = (crc >> 1) ^ 0xA001;
			}
			else
			{
				crc >>= 1;
			}
		}
	}
	return (ushort)crc;
}

// pdu empty or longer than 253 bytes -> BAD_LENGTH
fn usz? rtu_encode(char addr, char[] pdu, char[] out)
{
	if (pdu.len == 0 || pdu.len > modbus::MAX_PDU) return modbus::BAD_LENGTH~;
	usz total = 1 + pdu.len + 2;
	if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
	out[0] = addr;
	mem::copy(&out[1], pdu.ptr, (sz)pdu.len);
	ushort crc = crc16(out[:1 + pdu.len]);
	out[1 + pdu.len] = (char)(crc & 0xFF);
	out[2 + pdu.len] = (char)(crc >> 8);
	return total;
}

struct RtuFrame
{
	char addr;
	char[] pdu;          // borrowed from the input
}

// `frame` is one complete frame as delimited by the transport (3.5 character gap).
// Shorter than 4 bytes -> SHORT_FRAME; longer than 256 -> BAD_LENGTH; wrong CRC -> BAD_CRC.
fn RtuFrame? rtu_decode(char[] frame)
{
	if (frame.len < 4) return modbus::SHORT_FRAME~;
	if (frame.len > modbus::MAX_RTU_ADU) return modbus::BAD_LENGTH~;
	usz n = frame.len;
	ushort got = (ushort)(frame[n - 2] | ((ushort)frame[n - 1] << 8));
	if (crc16(frame[:n - 2]) != got) return modbus::BAD_CRC~;
	return { .addr = frame[0], .pdu = frame[1:n - 3] };
}
