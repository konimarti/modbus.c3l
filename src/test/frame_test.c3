module modbus::frame_test;

import std::core::mem;
import modbus;
import modbus::frame;
import modbus::support;

// Reference CRC, bit by bit and independent of the library's loop shape.
fn ushort ref_crc(char[] data)
{
	ushort crc = 0xFFFF;
	foreach (b : data)
	{
		crc = crc ^ (ushort)b;
		for (int i = 0; i < 8; i++)
		{
			ushort lsb = crc & 1;
			crc = crc >> 1;
			if (lsb != 0) crc = crc ^ 0xA001;
		}
	}
	return crc;
}

fn void test_version() @test
{
	assert(modbus::VERSION == "0.1.0");
}

// ---- CRC-16 (R0, R1, R2 and more) ----

fn void test_crc16_check_value() @test
{
	assert(frame::crc16("123456789") == 0x4B37);
}

fn void test_crc16_frames() @test
{
	@pool()
	{
		assert(frame::crc16(support::hx("01 03 00 00 00 0A")) == 0xCDC5);
		assert(frame::crc16(support::hx("01 04 02 FF FF")) == 0x80B8);
		assert(frame::crc16(support::hx("11 03 00 6B 00 03")) == 0x8776);
		assert(frame::crc16(support::hx("01 83 02")) == 0xF1C0);
	};
}

fn void test_crc16_matches_reference() @test
{
	char[64] data;
	uint seed = 12345;
	for (int round = 0; round < 50; round++)
	{
		for (usz i = 0; i < data.len; i++)
		{
			seed = seed * 1103515245 + 12345;
			data[i] = (char)(seed >> 16);
		}
		usz n = (usz)(round % 64) + 1;
		assert(frame::crc16(data[:n]) == ref_crc(data[:n]));
	}
}

// ---- MBAP encode (TV-M1, TV-M3, TV-M5, TV-M6) ----

fn void test_mbap_encode() @test
{
	@pool()
	{
		char[260] out;
		usz n = frame::mbap_encode(1, 0x11, support::hx("03 00 6B 00 03"), &out)!!;
		support::assert_bytes(out[:n], "00 01 00 00 00 06 11 03 00 6B 00 03", "TV-M1");
		n = frame::mbap_encode(1, 1, support::hx("03 00 6B 00 03"), &out)!!;
		support::assert_bytes(out[:n], "00 01 00 00 00 06 01 03 00 6B 00 03");
		n = frame::mbap_encode(0x0100, 0xFF, support::hx("06 00 01 00 03"), &out)!!;
		support::assert_bytes(out[:n], "01 00 00 00 00 06 FF 06 00 01 00 03", "TV-M3");
		n = frame::mbap_encode(3, 1, support::hx("11"), &out)!!;
		support::assert_bytes(out[:n], "00 03 00 00 00 02 01 11", "TV-M5");
		n = frame::mbap_encode(0xFFFF, 1, support::hx("03 00 00 00 0A"), &out)!!;
		support::assert_bytes(out[:n], "FF FF 00 00 00 06 01 03 00 00 00 0A", "TV-M6");
	};
}

fn void test_mbap_encode_limits() @test
{
	char[260] out;
	char[254] big;
	char[253] max;
	char[] none = {};
	assert(@catch(frame::mbap_encode(1, 1, none, &out)) == modbus::BAD_LENGTH);
	assert(@catch(frame::mbap_encode(1, 1, &big, &out)) == modbus::BAD_LENGTH);
	assert(frame::mbap_encode(1, 1, &max, &out)!! == 260);
	char[10] small;
	char[5] pdu;
	assert(@catch(frame::mbap_encode(1, 1, &pdu, &small)) == modbus::BUFFER_TOO_SMALL);
}

// ---- MBAP framer ----

fn void test_framer_one_frame() @test
{
	@pool()
	{
		MbapFramer f;
		char[] msg = support::hx("00 01 00 00 00 06 11 03 00 6B 00 03");
		assert(f.feed(msg) == msg.len);
		MbapFrame fr;
		assert(f.next(&fr)!!);
		assert(fr.header.tid == 1 && fr.header.proto == 0 && fr.header.length == 6 && fr.header.unit == 0x11);
		support::assert_bytes(fr.pdu, "03 00 6B 00 03");
		assert(!f.next(&fr)!!);
	};
}

fn void test_framer_byte_by_byte() @test
{
	@pool()
	{
		MbapFramer f;
		char[] msg = support::hx("00 01 00 00 00 06 11 03 00 6B 00 03");
		MbapFrame fr;
		foreach (i, b : msg)
		{
			assert(f.feed(msg[i:1]) == 1);
			bool got = f.next(&fr)!!;
			assert(got == (i == msg.len - 1), "frame appears only after the last byte (%d)", i);
		}
		support::assert_bytes(fr.pdu, "03 00 6B 00 03");
	};
}

fn void test_framer_split() @test
{
	@pool()
	{
		MbapFramer f;
		char[] msg = support::hx("00 01 00 00 00 06 11 03 00 6B 00 03");
		MbapFrame fr;
		f.feed(msg[:3]);
		assert(!f.next(&fr)!!);
		f.feed(msg[3..]);
		assert(f.next(&fr)!!);
		assert(fr.header.tid == 1);
	};
}

fn void test_framer_two_frames_in_one_buffer() @test
{
	@pool()
	{
		MbapFramer f;
		char[] msg = support::hx("00 01 00 00 00 06 11 03 00 6B 00 03 01 00 00 00 00 06 FF 06 00 01 00 03");
		assert(msg.len == 24);
		assert(f.feed(msg) == 24);
		MbapFrame fr;
		assert(f.next(&fr)!!);
		assert(fr.header.tid == 1);
		support::assert_bytes(fr.pdu, "03 00 6B 00 03");
		assert(f.next(&fr)!!);
		assert(fr.header.tid == 0x0100 && fr.header.unit == 0xFF);
		support::assert_bytes(fr.pdu, "06 00 01 00 03");
		assert(!f.next(&fr)!!);
	};
}

fn void test_framer_lazy_compaction() @test
{
	@pool()
	{
		MbapFramer f;
		f.feed(support::hx("00 01 00 00 00 06 11 03 00 6B 00 03 01 00 00 00 00 06 FF 06 00 01 00 03"));
		MbapFrame fr1;
		assert(f.next(&fr1)!!);
		// The slice of frame 1 is intact right after next(), although frame 2 is already buffered.
		support::assert_bytes(fr1.pdu, "03 00 6B 00 03", "frame 1 intact");
		MbapFrame fr2;
		assert(f.next(&fr2)!!);
		support::assert_bytes(fr2.pdu, "06 00 01 00 03", "frame 2");
		// Compaction left no stale bytes: feeding a third frame works.
		f.feed(support::hx("00 03 00 00 00 02 01 11"));
		MbapFrame fr3;
		assert(f.next(&fr3)!!);
		assert(fr3.header.tid == 3);
		support::assert_bytes(fr3.pdu, "11");
	};
}

fn void test_framer_leftover_kept() @test
{
	@pool()
	{
		// X8: first frame decoded, one leftover byte retained
		MbapFramer f;
		f.feed(support::hx("00 01 00 00 00 06 11 03 00 6B 00 03 00"));
		MbapFrame fr;
		assert(f.next(&fr)!!);
		assert(!f.next(&fr)!!);
		f.feed(support::hx("02 00 00 00 03 01 83 02"));
		assert(f.next(&fr)!!);
		assert(fr.header.tid == 2);
		support::assert_bytes(fr.pdu, "83 02");
	};
}

fn void test_framer_need_more() @test
{
	@pool()
	{
		MbapFrame fr;
		MbapFramer f;
		f.feed(support::hx("00 01 00 00 00 06 11 03 00 6B"));  // X6
		assert(!f.next(&fr)!!);
		MbapFramer g;
		g.feed(support::hx("00 01 00 00 00"));                  // X7
		assert(!g.next(&fr)!!);
	};
}

fn void test_framer_rejects() @test
{
	@pool()
	{
		MbapFrame fr;
		MbapFramer a;
		a.feed(support::hx("00 01 00 01 00 06 11 03 00 6B 00 03"));      // X1
		assert(@catch(a.next(&fr)) == modbus::BAD_PROTOCOL_ID);
		MbapFramer b;
		b.feed(support::hx("00 01 00 00 00 00 11 03"));                  // X2
		assert(@catch(b.next(&fr)) == modbus::BAD_LENGTH);
		MbapFramer c;
		c.feed(support::hx("00 01 00 00 00 01 11"));                     // X3
		assert(@catch(c.next(&fr)) == modbus::BAD_LENGTH);
		MbapFramer d;
		d.feed(support::hx("00 01 00 00 00 FF 11 03"));                  // X4: error without waiting for 255 bytes
		assert(@catch(d.next(&fr)) == modbus::BAD_LENGTH);
		MbapFramer e;
		e.feed(support::hx("00 01 00 00 FF FF 11 03"));                  // X5
		assert(@catch(e.next(&fr)) == modbus::BAD_LENGTH);
		// the longest legal length (254) is accepted and waits for its bytes
		MbapFramer g;
		g.feed(support::hx("00 01 00 00 00 FE 11 03"));
		assert(!g.next(&fr)!!);
	};
}

fn void test_framer_full_buffer_backpressure() @test
{
	MbapFramer f;
	char[1024] data;
	usz taken = f.feed(data[:600]);
	assert(taken == f.buf.len);
	assert(f.free_space() == 0);
	assert(f.feed(data[:10]) == 0);
}

// ---- RTU ----

fn void test_rtu_decode() @test
{
	@pool()
	{
		RtuFrame fr = frame::rtu_decode(support::hx("01 03 00 00 00 0A C5 CD"))!!;     // R1
		assert(fr.addr == 1);
		support::assert_bytes(fr.pdu, "03 00 00 00 0A");
		fr = frame::rtu_decode(support::hx("01 04 02 FF FF B8 80"))!!;                  // R2
		support::assert_bytes(fr.pdu, "04 02 FF FF");
		fr = frame::rtu_decode(support::hx("11 03 00 6B 00 03 76 87"))!!;               // R3
		assert(fr.addr == 0x11);
		fr = frame::rtu_decode(support::hx("11 03 06 AE 41 56 52 43 40 49 AD"))!!;      // R4
		support::assert_bytes(fr.pdu, "03 06 AE 41 56 52 43 40");
		fr = frame::rtu_decode(support::hx("01 01 00 13 00 13 8C 02"))!!;               // R5
		fr = frame::rtu_decode(support::hx("01 81 02 C1 91"))!!;                        // R6
		support::assert_bytes(fr.pdu, "81 02");
		fr = frame::rtu_decode(support::hx("01 83 02 C0 F1"))!!;                        // R7
		fr = frame::rtu_decode(support::hx("01 05 00 AC FF 00 4C 1B"))!!;               // R8
		fr = frame::rtu_decode(support::hx("01 06 00 01 00 03 98 0B"))!!;               // R9
		fr = frame::rtu_decode(support::hx("01 10 00 01 00 02 04 00 0A 01 02 92 30"))!!; // R10
		fr = frame::rtu_decode(support::hx("01 0F 00 13 00 0A 02 CD 01 72 CB"))!!;      // R11
		fr = frame::rtu_decode(support::hx("01 03 06 02 2B 00 00 00 64 05 7A"))!!;      // R12
		fr = frame::rtu_decode(support::hx("01 2B 0E 01 00 70 77"))!!;                  // R13
		fr = frame::rtu_decode(support::hx("01 11 C0 2C"))!!;                           // R14: smallest legal frame
		assert(fr.addr == 1);
		support::assert_bytes(fr.pdu, "11");
		fr = frame::rtu_decode(support::hx("01 17 00 03 00 06 00 0E 00 03 06 12 34 56 78 9A BC 6A C3"))!!; // R15
		assert(fr.pdu.len == 16);
		fr = frame::rtu_decode(support::hx("00 06 00 01 00 03 99 DA"))!!;               // R16: broadcast
		assert(fr.addr == 0);
	};
}

fn void test_rtu_decode_errors() @test
{
	@pool()
	{
		assert(@catch(frame::rtu_decode(support::hx("01 03 00 00 00 0A CD C5"))) == modbus::BAD_CRC);  // XR1 swapped CRC bytes
		assert(@catch(frame::rtu_decode(support::hx("01 03 00 00 00 0A C5 CC"))) == modbus::BAD_CRC);  // XR2
		assert(@catch(frame::rtu_decode(support::hx("01 03 C5"))) == modbus::SHORT_FRAME);             // XR3
		assert(@catch(frame::rtu_decode(support::hx("01 03 00"))) == modbus::SHORT_FRAME);             // XR4
		char[] none = {};
		assert(@catch(frame::rtu_decode(none)) == modbus::SHORT_FRAME);
		char[257] toolong;
		assert(@catch(frame::rtu_decode(&toolong)) == modbus::BAD_LENGTH);                        // XR5
		char[256] max;
		ushort crc = frame::crc16(max[:254]);
		max[254] = (char)(crc & 0xFF);
		max[255] = (char)(crc >> 8);
		assert(frame::rtu_decode(&max)!!.pdu.len == 253);                                      // longest legal frame
	};
}

fn void test_rtu_reserved_address_unchanged() @test
{
	@pool()
	{
		// XR6: address 0xF9 with a valid CRC is returned unchanged; policy is the caller's
		char[] body = support::hx("F9 03 02 00 01");
		ushort crc = frame::crc16(body);
		char[8] msg;
		mem::copy(&msg[0], body.ptr, 5);
		msg[5] = (char)(crc & 0xFF);
		msg[6] = (char)(crc >> 8);
		RtuFrame fr = frame::rtu_decode(msg[:7])!!;
		assert(fr.addr == 0xF9);
	};
}

fn void test_rtu_encode() @test
{
	@pool()
	{
		char[256] out;
		usz n = frame::rtu_encode(1, support::hx("03 00 00 00 0A"), &out)!!;
		support::assert_bytes(out[:n], "01 03 00 00 00 0A C5 CD", "R1");
		n = frame::rtu_encode(0, support::hx("06 00 01 00 03"), &out)!!;
		support::assert_bytes(out[:n], "00 06 00 01 00 03 99 DA", "R16");
		n = frame::rtu_encode(1, support::hx("11"), &out)!!;
		support::assert_bytes(out[:n], "01 11 C0 2C", "R14");
		// round trip
		char[3] pdu = { 0x03, 0x12, 0x34 };
		n = frame::rtu_encode(7, &pdu, &out)!!;
		RtuFrame fr = frame::rtu_decode(out[:n])!!;
		assert(fr.addr == 7);
		support::assert_bytes(fr.pdu, "03 12 34");
	};
}

fn void test_rtu_encode_limits() @test
{
	char[256] out;
	char[254] big;
	char[253] max;
	char[] none = {};
	assert(@catch(frame::rtu_encode(1, &big, &out)) == modbus::BAD_LENGTH);
	assert(@catch(frame::rtu_encode(1, none, &out)) == modbus::BAD_LENGTH);
	assert(frame::rtu_encode(1, &max, &out)!! == 256);
	char[4] small;
	char[3] pdu;
	assert(@catch(frame::rtu_encode(1, &pdu, &small)) == modbus::BUFFER_TOO_SMALL);
}
