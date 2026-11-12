module modbus::server2_test;

import std::core::mem;
import modbus;
import modbus::frame;
import modbus::pdu;
import modbus::server;
import modbus::support;

// A server connection over a register map with device identification, server id and diagnostics.
struct Rig
{
	RegisterMap map;
	ServerConfig cfg;
	ServerConn conn;
	pdu::DeviceObject[] objects;
	char last_unit;
}

fn void Rig.setup(&self, pdu::DeviceObject[] objects = {})
{
	self.map.init(mem, 100, 100, 300, 100)!!;
	self.cfg.accept_any_unit = true;
	self.cfg.device_objects = objects;
	self.cfg.conformity_level = 0x01;
	self.conn.init(&self.cfg, (DataModel)&self.map, mem)!!;
}

fn void Rig.teardown(&self)
{
	self.conn.free();
	self.map.free();
}

fn char[] Rig.call(&self, String pdu_hex, char unit = 1)
{
	return self.call_bytes(support::hx(pdu_hex), unit);
}

fn char[] Rig.call_bytes(&self, char[] pdu, char unit = 1)
{
	char[300] adu;
	usz n = frame::mbap_encode(1, unit, pdu, &adu)!!;
	assert(self.conn.feed(adu[:n])!! == n);
	char[] o = self.conn.output();
	if (o.len == 0) return {};
	usz len = (usz)(((ushort)o[4] << 8) | o[5]);
	assert(o.len == 6 + len, "one answer per request");
	self.last_unit = o[6];
	char[] resp = mem::temp_array(char, (sz)(len - 1));
	mem::copy(resp.ptr, &o[7], (sz)(len - 1));
	self.conn.consume_output(o.len);
	return resp;
}

// ---- FC 22 mask write (V17, V18) ----

fn void test_mask_write_example() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		r.map.holding[4] = 0x0012;
		support::assert_bytes(r.call("16 00 04 00 F2 00 25"), "16 00 04 00 F2 00 25");           // V17, V18
		assert(r.map.holding[4] == 0x0017);                                                      // (0x12 & 0xF2) | (0x25 & ~0xF2)
		r.map.holding[5] = 0xFFFF;
		r.call("16 00 05 00 00 12 34");                                                          // AND 0: the OR mask is the result
		assert(r.map.holding[5] == 0x1234);
		r.map.holding[6] = 0xABCD;
		r.call("16 00 06 FF FF 12 34");                                                          // AND all ones: unchanged
		assert(r.map.holding[6] == 0xABCD);
	};
}

fn void test_mask_write_errors() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		support::assert_bytes(r.call("16 FF FF 00 F2 00 25"), "96 02");
		support::assert_bytes(r.call("16 01 2C 00 F2 00 25"), "96 02");                          // 300 is one past the end
		support::assert_bytes(r.call("16 00 04 00 F2 00"), "96 03");
		r.map.read_only = true;
		r.map.holding[4] = 0x12;
		support::assert_bytes(r.call("16 00 04 00 F2 00 25"), "96 01");
		assert(r.map.holding[4] == 0x12);
	};
}

// ---- FC 23 read/write (V19, V20, S7) ----

fn void test_read_write_example() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		ushort[6] seed = { 0x00FE, 0x0ACD, 0x0001, 0x0003, 0x000D, 0x00FF };
		for (usz i = 0; i < 6; i++) r.map.holding[3 + i] = seed[i];
		support::assert_bytes(r.call("17 00 03 00 06 00 0E 00 03 06 12 34 56 78 9A BC"), "17 0C 00 FE 0A CD 00 01 00 03 00 0D 00 FF");   // V19, V20
		assert(r.map.holding[14] == 0x1234 && r.map.holding[15] == 0x5678 && r.map.holding[16] == 0x9ABC);
	};
}

fn void test_read_write_reads_what_it_wrote() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		r.map.holding[10] = 0x0001;
		r.map.holding[13] = 0x0004;
		// write 10..12, read 11..13: the read sees the new values (S7)
		support::assert_bytes(r.call("17 00 0B 00 03 00 0A 00 03 06 AA AA BB BB CC CC"), "17 06 BB BB CC CC 00 04");
		// read range equal to the write range
		support::assert_bytes(r.call("17 00 20 00 02 00 20 00 02 04 11 11 22 22"), "17 04 11 11 22 22");
	};
}

fn void test_read_write_bad_range_changes_nothing() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		r.map.holding[0] = 0x7777;
		// valid write range, read range runs past the end: exception and no write
		support::assert_bytes(r.call("17 01 2B 00 02 00 00 00 01 02 11 11"), "97 02");
		assert(r.map.holding[0] == 0x7777);
		// valid read range, write range runs past the end
		support::assert_bytes(r.call("17 00 00 00 01 01 2B 00 02 04 11 11 22 22"), "97 02");
		assert(r.map.holding[0] == 0x7777 && r.map.holding[299] == 0);
		r.map.read_only = true;
		support::assert_bytes(r.call("17 00 00 00 01 00 00 00 01 02 11 11"), "97 01");
		assert(r.map.holding[0] == 0x7777);
	};
}

fn void test_read_write_limits() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		support::assert_bytes(r.call("17 00 00 00 7E 00 00 00 01 02 00 01"), "97 03");           // L20
		// L21 needs a 254-byte PDU: a shortened variant with the same quantity
		support::assert_bytes(r.call("17 00 00 00 01 00 00 00 7A 02 00 01"), "97 03");
		support::assert_bytes(r.call("17 00 00 00 01 00 00 00 01 04 00 01"), "97 03");           // L22
		assert(r.map.holding[0] == 0);
		// the largest legal request
		char[] big = support::padded("17 00 00 00 7D 00 00 00 79 F2", 242);
		char[] answer = r.call_bytes(big);
		assert(answer.len == 252 && answer[0] == 0x17 && answer[1] == 250);
		// lowered limits apply to both parts
		r.cfg.max_read_regs = 10;
		r.cfg.max_write_regs = 3;
		support::assert_bytes(r.call("17 00 00 00 0B 00 00 00 01 02 00 01"), "97 03");
		support::assert_bytes(r.call("17 00 00 00 01 00 00 00 04 08 00 01 00 02 00 03 00 04"), "97 03");
		assert(r.call("17 00 00 00 0A 00 00 00 03 06 00 01 00 02 00 03").len == 22);
	};
}

// ---- FC 8 diagnostics (V21, V22) ----

fn void test_diagnostics_echo() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		support::assert_bytes(r.call("08 00 00 A5 37"), "88 01");                                // disabled by default
		r.cfg.allow_diagnostics = true;
		support::assert_bytes(r.call("08 00 00 A5 37"), "08 00 00 A5 37");                       // V21, V22
		support::assert_bytes(r.call("08 00 00 12 34 56 78"), "08 00 00 12 34 56 78");
		support::assert_bytes(r.call("08 00 01 FF 00"), "88 01");                                // other sub-functions are not implemented
		support::assert_bytes(r.call("08 00 00 12"), "88 03");
		support::assert_bytes(r.call("08 00 00"), "88 03");
		support::assert_bytes(r.call("08 00 00 12 34 56"), "88 03");
		char[] answer = r.call_bytes(support::padded("08 00 00", 250));
		assert(answer.len == 253);
	};
}

// ---- FC 0x11 report server id ----

fn void test_report_server_id() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		support::assert_bytes(r.call("11"), "91 01");                                            // nothing configured
		r.cfg.server_id = support::hx("01 FF 41 42");
		support::assert_bytes(r.call("11"), "11 04 01 FF 41 42");                                // V24 style
		support::assert_bytes(r.call("11 00"), "91 03");
	};
}

// ---- FC 43/14 (V25 to V29, L23 to L27) ----

fn pdu::DeviceObject[] basic_objects()
{
	pdu::DeviceObject[] o = mem::temp_array(pdu::DeviceObject, 4);
	o[0] = { 0x00, "ABC" };
	o[1] = { 0x01, "XY" };
	o[2] = { 0x02, "1.0" };
	o[3] = { 0x05, "M1" };
	return o;
}

fn void test_device_id_basic_stream() @test
{
	@pool()
	{
		Rig r;
		r.setup(basic_objects());
		defer r.teardown();
		support::assert_bytes(r.call("2B 0E 01 00"), "2B 0E 01 01 00 00 03 00 03 41 42 43 01 02 58 59 02 03 31 2E 30");   // V25, V26
		// start in the middle
		support::assert_bytes(r.call("2B 0E 01 01"), "2B 0E 01 01 00 00 02 01 02 58 59 02 03 31 2E 30");
		// an unknown start id restarts at the first object (verify against a real device)
		support::assert_bytes(r.call("2B 0E 01 50"), "2B 0E 01 01 00 00 03 00 03 41 42 43 01 02 58 59 02 03 31 2E 30");
		// object 5 is not a basic object: not part of the stream
		support::assert_bytes(r.call("2B 0E 02 00"), "2B 0E 02 01 00 00 01 05 02 4D 31");
	};
}

fn void test_device_id_individual_access() @test
{
	@pool()
	{
		Rig r;
		r.cfg.conformity_level = 0x81;
		r.setup(basic_objects());
		r.cfg.conformity_level = 0x81;
		defer r.teardown();
		support::assert_bytes(r.call("2B 0E 04 05"), "2B 0E 04 81 00 00 01 05 02 4D 31");        // V27, V28
		support::assert_bytes(r.call("2B 0E 04 00"), "2B 0E 04 81 00 00 01 00 03 41 42 43");
		support::assert_bytes(r.call("2B 0E 04 FF"), "AB 02");                                   // L25: no such object
		support::assert_bytes(r.call("2B 0E 04 03"), "AB 02");
	};
}

fn void test_device_id_errors() @test
{
	@pool()
	{
		Rig r;
		r.setup(basic_objects());
		defer r.teardown();
		support::assert_bytes(r.call("2B 0E 05 00"), "AB 03");                                   // L23
		support::assert_bytes(r.call("2B 0E 00 00"), "AB 03");                                   // L24
		support::assert_bytes(r.call("2B 0D 00 00"), "AB 01");                                   // L26
		support::assert_bytes(r.call("2B 0E 01"), "AB 03");                                      // L27
		support::assert_bytes(r.call("2B 0E 01 00 00"), "AB 03");
		// no objects in the requested category: an empty, valid answer
		support::assert_bytes(r.call("2B 0E 03 00"), "2B 0E 03 01 00 00 00");
	};
}

fn pdu::DeviceObject[] big_objects(usz n, usz size)
{
	pdu::DeviceObject[] o = mem::temp_array(pdu::DeviceObject, (sz)n);
	char[] text = mem::temp_array(char, (sz)size);
	for (usz i = 0; i < size; i++) text[i] = (char)('a' + i % 26);
	for (usz i = 0; i < n; i++) o[i] = { (char)i, (String)text };
	return o;
}

fn void test_device_id_continuation() @test
{
	@pool()
	{
		Rig r;
		r.setup(big_objects(3, 100));                                    // basic objects 0, 1, 2 of 100 bytes each
		defer r.teardown();
		char[] first = r.call("2B 0E 01 00");
		assert(first.len == 7 + 2 * 102);
		assert(first[4] == 0xFF && first[5] == 2 && first[6] == 2, "more follows, next object 2, two objects");   // V29 style
		assert(first.len <= modbus::MAX_PDU);
		char[] second = r.call("2B 0E 01 02");
		assert(second.len == 7 + 102);
		assert(second[4] == 0x00 && second[5] == 0 && second[6] == 1);
		assert(second[7] == 2);
	};
}

fn void test_device_id_exact_fit_has_no_continuation() @test
{
	@pool()
	{
		Rig r;
		// 7 + 2 * 123 = 253: two objects of 121 bytes fill the PDU exactly
		r.setup(big_objects(2, 121));
		defer r.teardown();
		char[] a = r.call("2B 0E 01 00");
		assert(a.len == 253 && a[4] == 0x00 && a[6] == 2);
		// one byte more and the second object moves to the next answer
		Rig s;
		pdu::DeviceObject[] o = big_objects(2, 122);
		s.setup(o);
		defer s.teardown();
		char[] b = s.call("2B 0E 01 00");
		assert(b.len == 7 + 124 && b[4] == 0xFF && b[5] == 1 && b[6] == 1);
	};
}

fn void test_device_id_split_is_exact_at_the_pdu_limit() @test
{
	@pool()
	{
		Rig r;
		// objects of 122 and 121 bytes would make a 254-byte PDU: the second one moves to the next answer
		pdu::DeviceObject[] o = mem::temp_array(pdu::DeviceObject, 2);
		char[] text = mem::temp_array(char, 122);
		o[0] = { 0, (String)text[:122] };
		o[1] = { 1, (String)text[:121] };
		r.setup(o);
		defer r.teardown();
		char[] a = r.call("2B 0E 01 00");
		assert(a.len == 7 + 124 && a[4] == 0xFF && a[5] == 1 && a[6] == 1);
		char[] b = r.call("2B 0E 01 01");
		assert(b.len == 7 + 123 && b[4] == 0x00 && b[6] == 1);
	};
}

fn void test_config_checks() @test
{
	@pool()
	{
		RegisterMap m;
		m.init(mem, 1, 1, 1, 1)!!;
		defer m.free();
		ServerConfig cfg = { .accept_any_unit = true };
		ServerConn c;
		pdu::DeviceObject[] big = big_objects(1, 245);
		cfg.device_objects = big;
		assert(@catch(c.init(&cfg, (DataModel)&m, mem)) == modbus::BAD_LENGTH);
		big = big_objects(1, 244);
		cfg.device_objects = big;
		c.init(&cfg, (DataModel)&m, mem)!!;
		c.free();
		pdu::DeviceObject[] unordered = mem::temp_array(pdu::DeviceObject, 2);
		unordered[0] = { 2, "a" };
		unordered[1] = { 1, "b" };
		cfg.device_objects = unordered;
		assert(@catch(c.init(&cfg, (DataModel)&m, mem)) == modbus::BAD_VALUE);
		unordered[1] = { 2, "b" };
		assert(@catch(c.init(&cfg, (DataModel)&m, mem)) == modbus::BAD_VALUE);
		cfg.device_objects = {};
		char[251] id;
		cfg.server_id = &id;
		assert(@catch(c.init(&cfg, (DataModel)&m, mem)) == modbus::BAD_LENGTH);
	};
}

fn void test_largest_object_fits() @test
{
	@pool()
	{
		Rig r;
		r.setup(big_objects(1, 244));
		defer r.teardown();
		char[] a = r.call("2B 0E 01 00");
		assert(a.len == 7 + 2 + 244 && a[4] == 0x00 && a[6] == 1);
	};
}

// ---- RTU through handle_rtu ----

struct RtuRig
{
	RegisterMap map;
	ServerConfig cfg;
}

fn void RtuRig.setup(&self)
{
	self.map.init(mem, 100, 100, 300, 300)!!;
	self.cfg.accept_any_unit = true;
}

// Encodes a request frame, runs it, returns the answer frame ({} when there is none).
fn char[] RtuRig.call(&self, char addr, String pdu_hex)
{
	char[256] frame;
	usz n = frame::rtu_encode(addr, support::hx(pdu_hex), &frame)!!;
	return self.call_frame(frame[:n]);
}

fn char[] RtuRig.call_frame(&self, char[] frame)
{
	char[256] out;
	usz n = server::handle_rtu(&self.cfg, (DataModel)&self.map, frame, &out)!!;
	if (n == 0) return {};
	char[] copy = mem::temp_array(char, (sz)n);
	mem::copy(copy.ptr, &out[0], (sz)n);
	return copy;
}

fn void test_rtu_read_answers() @test
{
	@pool()
	{
		RtuRig r;
		r.setup();
		defer r.map.free();
		r.map.holding[107] = 0xAE41;
		r.map.holding[108] = 0x5652;
		r.map.holding[109] = 0x4340;
		support::assert_bytes(r.call_frame(support::hx("11 03 00 6B 00 03 76 87")), "11 03 06 AE 41 56 52 43 40 49 AD", "R3, R4");
		r.map.holding[1] = 555;
		r.map.holding[3] = 100;
		support::assert_bytes(r.call(1, "03 00 01 00 03"), "01 03 06 02 2B 00 00 00 64 05 7A", "R12");
		r.map.input[0] = 0xFFFF;
		support::assert_bytes(r.call(1, "04 00 00 00 01"), "01 04 02 FF FF B8 80", "R2");
		// R1: ten holding registers from 0
		char[] a = r.call_frame(support::hx("01 03 00 00 00 0A C5 CD"));
		RtuFrame f = frame::rtu_decode(a)!!;
		assert(f.addr == 1 && f.pdu.len == 22 && f.pdu[0] == 3 && f.pdu[1] == 20);
		// R5: coils 19 to 37
		a = r.call_frame(support::hx("01 01 00 13 00 13 8C 02"));
		f = frame::rtu_decode(a)!!;
		assert(f.pdu.len == 5 && f.pdu[0] == 1 && f.pdu[1] == 3);
	};
}

fn void test_rtu_exceptions() @test
{
	@pool()
	{
		RtuRig r;
		r.setup();
		defer r.map.free();
		support::assert_bytes(r.call(1, "01 FF FF 00 01"), "01 81 02 C1 91", "R6");
		support::assert_bytes(r.call(1, "03 FF FF 00 01"), "01 83 02 C0 F1", "R7");
	};
}

fn void test_rtu_unmapped_write_is_an_exception_frame() @test
{
	@pool()
	{
		RtuRig r;
		r.setup();
		defer r.map.free();
		// coil 172 does not exist in a map of 100 coils
		char[] a = r.call_frame(support::hx("01 05 00 AC FF 00 4C 1B"));
		RtuFrame f = frame::rtu_decode(a)!!;
		assert(f.addr == 1);
		support::assert_bytes(f.pdu, "85 02");
	};
}

fn void test_rtu_write_vectors() @test
{
	@pool()
	{
		RtuRig r;
		r.map.init(mem, 300, 100, 300, 300)!!;
		r.cfg.accept_any_unit = true;
		defer r.map.free();
		support::assert_bytes(r.call_frame(support::hx("01 05 00 AC FF 00 4C 1B")), "01 05 00 AC FF 00 4C 1B", "R8");
		assert(r.map.coils[172]);
		support::assert_bytes(r.call_frame(support::hx("01 06 00 01 00 03 98 0B")), "01 06 00 01 00 03 98 0B", "R9");
		assert(r.map.holding[1] == 3);
		support::assert_bytes(r.call_frame(support::hx("01 10 00 01 00 02 04 00 0A 01 02 92 30")), "01 10 00 01 00 02 10 08", "R10");
		assert(r.map.holding[1] == 0x000A && r.map.holding[2] == 0x0102);
		char[] a = r.call_frame(support::hx("01 0F 00 13 00 0A 02 CD 01 72 CB"));                                // R11
		RtuFrame f = frame::rtu_decode(a)!!;
		support::assert_bytes(f.pdu, "0F 00 13 00 0A");
		assert(r.map.coils[19] && !r.map.coils[20] && r.map.coils[21]);
		a = r.call_frame(support::hx("01 17 00 03 00 06 00 0E 00 03 06 12 34 56 78 9A BC 6A C3"));              // R15
		f = frame::rtu_decode(a)!!;
		assert(f.pdu[0] == 0x17 && f.pdu[1] == 12);
		assert(r.map.holding[14] == 0x1234);
	};
}

fn void test_rtu_device_id_and_server_id() @test
{
	@pool()
	{
		RtuRig r;
		r.setup();
		defer r.map.free();
		r.cfg.device_objects = basic_objects();
		r.cfg.server_id = support::hx("01 FF");
		r.cfg.conformity_level = 1;
		char[] a = r.call_frame(support::hx("01 2B 0E 01 00 70 77"));                                            // R13
		RtuFrame f = frame::rtu_decode(a)!!;
		assert(f.pdu[0] == 0x2B && f.pdu[6] == 3);
		a = r.call_frame(support::hx("01 11 C0 2C"));                                                            // R14
		f = frame::rtu_decode(a)!!;
		support::assert_bytes(f.pdu, "11 02 01 FF");
	};
}

fn void test_rtu_broadcast() @test
{
	@pool()
	{
		RtuRig r;
		r.setup();
		defer r.map.free();
		assert(r.call_frame(support::hx("00 06 00 01 00 03 99 DA")).len == 0);                                   // R16: executed, not answered
		assert(r.map.holding[1] == 3);
		// reads are not broadcast: ignored
		r.map.holding[2] = 9;
		assert(r.call(0, "03 00 02 00 01").len == 0);
		// a broadcast reaches the device even when its own address list does not contain 0
		r.cfg.accept_any_unit = false;
		char[1] mine = { 1 };
		r.cfg.units = &mine;
		assert(r.call(0, "06 00 04 00 07").len == 0);
		assert(r.map.holding[4] == 7);
	};
}

fn void test_rtu_ignored_frames() @test
{
	@pool()
	{
		RtuRig r;
		r.setup();
		defer r.map.free();
		// bad CRC (XR1 swapped, XR2 flipped bit): nothing executed, nothing answered
		assert(r.call_frame(support::hx("01 06 00 01 00 03 0B 98")).len == 0);
		assert(r.call_frame(support::hx("01 06 00 01 00 03 98 0A")).len == 0);
		assert(r.map.holding[1] == 0);
		// too short, empty
		assert(r.call_frame(support::hx("01 03 C5")).len == 0);
		char[] none = {};
		assert(r.call_frame(none).len == 0);
		// reserved addresses 248 to 255
		foreach (a : (char[]){ 248, 249, 255 })
		{
			assert(r.call(a, "06 00 01 00 05").len == 0, "address %d", a);
		}
		assert(r.map.holding[1] == 0);
		// an address that is not in the list
		r.cfg.accept_any_unit = false;
		char[1] mine = { 7 };
		r.cfg.units = &mine;
		assert(r.call(1, "06 00 01 00 05").len == 0);
		assert(r.call(7, "06 00 01 00 05").len == 8);
		assert(r.map.holding[1] == 5);
		// an exception function code in a request: no answer
		assert(r.call(7, "86 00").len == 0);
		// output too small for the answer
		char[4] tiny;
		char[10] req;
		usz n = frame::rtu_encode(7, support::hx("06 00 01 00 05"), &req)!!;
		assert(@catch(server::handle_rtu(&r.cfg, (DataModel)&r.map, req[:n], &tiny)) == modbus::BUFFER_TOO_SMALL);
	};
}
