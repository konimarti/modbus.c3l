module modbus::server_test;

import std::core::mem;
import modbus;
import modbus::frame;
import modbus::server;
import modbus::support;

// A server connection over a register map; the answers of call() are PDUs.
struct Rig
{
	RegisterMap map;
	ServerConfig cfg;
	ServerConn conn;
	ushort last_tid;
	char last_unit;
}

fn void Rig.setup(&self, usz coils = 2100, usz discrete = 300, usz holding = 300, usz input = 300)
{
	self.map.init(mem, coils, discrete, holding, input)!!;
	self.cfg.accept_any_unit = true;
	self.conn.init(&self.cfg, (DataModel)&self.map, mem)!!;
}

fn void Rig.teardown(&self)
{
	self.conn.free();
	self.map.free();
}

// Sends one request ADU (tid, unit) and returns the PDU of the first answer ({} when there is none).
fn char[] Rig.call(&self, String pdu_hex, char unit = 1, ushort tid = 1)
{
	return self.call_bytes(support::hx(pdu_hex), unit, tid);
}

fn char[] Rig.call_bytes(&self, char[] pdu, char unit = 1, ushort tid = 1)
{
	char[300] adu;
	usz n = frame::mbap_encode(tid, unit, pdu, &adu)!!;
	usz taken = self.conn.feed(adu[:n])!!;
	assert(taken == n);
	return self.take();
}

// Removes the first answer frame from the output and returns its PDU.
fn char[] Rig.take(&self)
{
	char[] o = self.conn.output();
	if (o.len == 0) return {};
	assert(o.len >= 8);
	assert(o[2] == 0 && o[3] == 0, "protocol id");
	usz len = (usz)(((ushort)o[4] << 8) | o[5]);
	assert(o.len >= 6 + len);
	self.last_tid = (ushort)(((ushort)o[0] << 8) | o[1]);
	self.last_unit = o[6];
	char[] pdu = mem::temp_array(char, (sz)(len - 1));
	mem::copy(pdu.ptr, &o[7], (sz)(len - 1));
	self.conn.consume_output(6 + len);
	return pdu;
}

fn void set_bits(bool[] dst, usz start, String bytes_hex, usz n)
{
	char[] b = support::hx(bytes_hex);
	for (usz i = 0; i < n; i++) dst[start + i] = ((b[i / 8] >> (i % 8)) & 1) != 0;
}

// ---- spec examples: V1 to V16 ----

fn void test_read_coils_example() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		set_bits(r.map.coils, 19, "CD 6B 05", 19);
		support::assert_bytes(r.call("01 00 13 00 13"), "01 03 CD 6B 05");                     // V1, V2
		assert(r.last_tid == 1 && r.last_unit == 1);
	};
}

fn void test_read_discrete_example() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		set_bits(r.map.discrete, 196, "AC DB 35", 22);
		support::assert_bytes(r.call("02 00 C4 00 16"), "02 03 AC DB 35");                     // V3, V4
	};
}

fn void test_read_holding_and_input_examples() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		r.map.holding[107] = 555;
		r.map.holding[109] = 100;
		support::assert_bytes(r.call("03 00 6B 00 03"), "03 06 02 2B 00 00 00 64");           // V5, V6
		r.map.input[8] = 10;
		support::assert_bytes(r.call("04 00 08 00 01"), "04 02 00 0A");                        // V7, V8
	};
}

fn void test_write_single_examples() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		support::assert_bytes(r.call("05 00 AC FF 00"), "05 00 AC FF 00");                     // V9, V10
		assert(r.map.coils[172]);
		support::assert_bytes(r.call("05 00 AC 00 00"), "05 00 AC 00 00");
		assert(!r.map.coils[172]);
		support::assert_bytes(r.call("06 00 01 00 03"), "06 00 01 00 03");                     // V11, V12
		assert(r.map.holding[1] == 3);
	};
}

fn void test_write_multiple_examples() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		support::assert_bytes(r.call("0F 00 13 00 0A 02 CD 01"), "0F 00 13 00 0A");             // V13, V14
		bool[10] want = { true, false, true, true, false, false, true, true, true, false };
		for (usz i = 0; i < 10; i++) assert(r.map.coils[19 + i] == want[i], "coil %d", i);
		assert(!r.map.coils[18] && !r.map.coils[29]);
		support::assert_bytes(r.call("10 00 01 00 02 04 00 0A 01 02"), "10 00 01 00 02");       // V15, V16
		assert(r.map.holding[1] == 0x000A && r.map.holding[2] == 0x0102);
		assert(r.map.holding[0] == 0 && r.map.holding[3] == 0);
	};
}

fn void test_write_then_read_back() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		r.call("10 00 10 00 03 06 11 11 22 22 33 33");
		support::assert_bytes(r.call("03 00 10 00 03"), "03 06 11 11 22 22 33 33");
		r.call("0F 00 00 00 09 02 FF 01");
		support::assert_bytes(r.call("01 00 00 00 0A"), "01 02 FF 01");                         // 9 coils on, unused bits zero
	};
}

fn void test_tid_and_unit_are_echoed() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		r.call("06 00 01 00 03", 0x11, 0x1234);
		assert(r.last_tid == 0x1234 && r.last_unit == 0x11);
		// TV-M3: unit 0xFF, tid 0x0100, raw bytes
		char[] adu = support::hx("01 00 00 00 00 06 FF 06 00 01 00 03");
		assert(r.conn.feed(adu)!! == adu.len);
		support::assert_bytes(r.conn.output(), "01 00 00 00 00 06 FF 06 00 01 00 03", "TV-M3");
	};
}

// ---- exceptions: V33, L1 to L19, L28 to L30 ----

fn void test_unmapped_address_example() @test
{
	@pool()
	{
		Rig r;
		r.setup(200, 200, 200, 200);
		defer r.teardown();
		support::assert_bytes(r.call("01 04 A1 00 01"), "81 02");                               // V33
		support::assert_bytes(r.call("03 FF FF 00 01"), "83 02");                               // L8: address 0xFFFF does not exist
		support::assert_bytes(r.call("03 FF FF 00 02"), "83 02");                               // L7
		support::assert_bytes(r.call("03 00 C7 00 02"), "83 02");                               // 199 + 2 > 200
		support::assert_bytes(r.call("03 00 C7 00 01"), "03 02 00 00");                         // last register exists
	};
}

fn void test_read_limits() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		support::assert_bytes(r.call("01 00 00 00 00"), "81 03");                               // L1
		support::assert_bytes(r.call("01 00 00 07 D1"), "81 03");                               // L2
		char[] all = r.call("01 00 00 07 D0");                                                  // L3: 2000 coils
		assert(all.len == 252 && all[0] == 1 && all[1] == 250);
		support::assert_bytes(r.call("03 00 00 00 00"), "83 03");                               // L4
		support::assert_bytes(r.call("03 00 00 00 7E"), "83 03");                               // L5
		char[] regs = r.call("03 00 00 00 7D");                                                 // L6: 125 registers
		assert(regs.len == 252 && regs[0] == 3 && regs[1] == 250);
		support::assert_bytes(r.call("04 00 00 00 7E"), "84 03");
		support::assert_bytes(r.call("02 00 00 07 D1"), "82 03");
	};
}

fn void test_write_single_limits() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		support::assert_bytes(r.call("05 00 01 00 01"), "85 03");                               // L9
		support::assert_bytes(r.call("05 00 01 FF FF"), "85 03");                               // L10
		assert(!r.map.coils[1]);
		support::assert_bytes(r.call("05 FF FF FF 00"), "85 02");                               // unmapped coil
		support::assert_bytes(r.call("06 FF FF 00 01"), "86 02");
	};
}

fn void test_write_multiple_limits() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		support::assert_bytes(r.call("0F 00 00 00 00 00"), "8F 03");                            // L11
		support::assert_bytes(r.call_bytes(support::padded("0F 00 00 07 B1 F7", 247)), "8F 03"); // L12
		support::assert_bytes(r.call("0F 00 00 00 0A 01 FF"), "8F 03");                         // L13
		support::assert_bytes(r.call("0F 00 00 00 0A 03 FF FF FF"), "8F 03");                   // L14
		support::assert_bytes(r.call("10 00 00 00 00 00"), "90 03");                            // L15
		support::assert_bytes(r.call("10 00 00 00 7C 04 00 01 00 02"), "90 03");                // L16 (shortened: see below)
		support::assert_bytes(r.call("10 00 00 00 02 03 00 01 00"), "90 03");                   // L17
		support::assert_bytes(r.call("10 00 00 00 02 04 00 01"), "90 03");                      // L18
		support::assert_bytes(r.call("10 00 00 00 02 04 00 01 00 02 00"), "90 03");             // L19
		assert(r.map.holding[0] == 0 && r.map.holding[1] == 0);
		// the largest legal writes still work
		support::assert_bytes(r.call_bytes(support::padded("10 00 00 00 7B F6", 246)), "10 00 00 00 7B");
		support::assert_bytes(r.call_bytes(support::padded("0F 00 00 07 B0 F6", 246)), "0F 00 00 07 B0");
	};
}

// L16 as written needs a 254-byte PDU, which an MBAP frame cannot carry (length 255): the stream is broken.
fn void test_pdu_too_long_for_mbap_breaks_the_stream() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		char[] adu = support::padded("00 01 00 00 00 FF 01 10 00 00 00 7C F8", 248);
		assert(@catch(r.conn.feed(adu)) == modbus::BAD_LENGTH);
		assert(@catch(r.conn.feed(adu)) == modbus::CLOSED);
		assert(@catch(r.conn.pump()) == modbus::CLOSED);
	};
}

fn void test_unknown_and_reserved_function_codes() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		support::assert_bytes(r.call("41 00 00"), "C1 01");                                     // L30
		support::assert_bytes(r.call("00 00 01"), "80 01");                                     // L28
		assert(r.call("80 00").len == 0);                                                       // L29: not a request, no answer
		assert(r.call("FF 00").len == 0);
		assert(r.conn.output().len == 0);
		support::assert_bytes(r.call("07"), "87 01");
		// functions the library does not implement (file records, FIFO queue, other MEI types)
		support::assert_bytes(r.call("14 00"), "94 01");
		support::assert_bytes(r.call("18 00 00"), "98 01");
		support::assert_bytes(r.call("2B 0D 00 00"), "AB 01");
	};
}

// ---- unit rules (S6, TV-M3) ----

fn void test_unit_filter() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		r.cfg.accept_any_unit = false;
		char[2] list = { 1, 7 };
		r.cfg.units = &list;
		support::assert_bytes(r.call("06 00 01 00 03", 1), "06 00 01 00 03");
		support::assert_bytes(r.call("06 00 01 00 04", 7), "06 00 01 00 04");
		assert(r.last_unit == 7);
		assert(r.call("06 00 01 00 05", 2).len == 0);                                           // S6: not ours, no answer
		assert(r.call("06 00 01 00 05", 0).len == 0);                                           // unit 0 only with accept_any_unit
		assert(r.call("06 00 01 00 05", 0xFF).len == 0);
		assert(r.map.holding[1] == 4);
		r.cfg.accept_any_unit = true;
		support::assert_bytes(r.call("06 00 01 00 05", 0), "06 00 01 00 05");
		assert(r.last_unit == 0);
		support::assert_bytes(r.call("06 00 01 00 06", 0xFF), "06 00 01 00 06");
		assert(r.last_unit == 0xFF);
	};
}

// ---- no partial writes (S8) ----

fn void test_multi_write_with_unmapped_tail_writes_nothing() @test
{
	@pool()
	{
		Rig r;
		r.setup(100, 100, 10, 10);
		defer r.teardown();
		r.map.holding[9] = 0x7777;
		support::assert_bytes(r.call("10 00 09 00 02 04 11 11 22 22"), "90 02");                // S8: register 10 is unmapped
		assert(r.map.holding[9] == 0x7777);
		r.map.coils[99] = false;
		support::assert_bytes(r.call("0F 00 63 00 02 01 03"), "8F 02");                         // coil 100 is unmapped
		assert(!r.map.coils[99]);
		// the same write inside the map works
		support::assert_bytes(r.call("10 00 08 00 02 04 11 11 22 22"), "10 00 08 00 02");
		assert(r.map.holding[8] == 0x1111 && r.map.holding[9] == 0x2222);
	};
}

// ---- backpressure and the quiet peer ----

fn void test_pipelined_requests_with_one_answer_of_room() @test
{
	@pool()
	{
		Rig r;
		r.cfg.output_size = 260;                       // room for one answer at a time
		r.setup();
		defer r.teardown();
		char[512] batch;
		usz at = 0;
		for (ushort i = 1; i <= 5; i++)
		{
			char[] req = support::hx("06 00 00 00 00");
			req[4] = (char)i;
			at += frame::mbap_encode(i, 1, req, batch[at..])!!;
		}
		assert(r.conn.feed(batch[:at])!! == at);
		// exactly one request was executed: the output holds one answer
		assert(r.conn.output().len == 12);
		assert(r.map.holding[0] == 1);
		// drain and pump without any new input: the buffered requests are answered in order
		for (ushort i = 1; i <= 5; i++)
		{
			char[] a = r.take();
			assert(a.len == 5, "answer %d", i);
			assert(r.last_tid == i && a[4] == (char)i);
			usz done = r.conn.pump()!!;
			assert(done == (i < 5 ? (usz)1 : (usz)0), "pump after answer %d", i);
		}
		assert(r.map.holding[0] == 5);
		assert(r.conn.output().len == 0);
	};
}

fn void test_empty_feed_is_pump() @test
{
	@pool()
	{
		Rig r;
		r.cfg.output_size = 260;
		r.setup();
		defer r.teardown();
		char[] two = support::hx("00 01 00 00 00 06 01 06 00 00 00 01 00 02 00 00 00 06 01 06 00 00 00 02");
		assert(r.conn.feed(two)!! == two.len);
		assert(r.take().len == 5 && r.last_tid == 1);
		char[] none = {};
		assert(r.conn.feed(none)!! == 0);                         // no new bytes: the second request is answered now
		assert(r.take().len == 5 && r.last_tid == 2);
		assert(r.map.holding[0] == 2);
	};
}

fn void test_request_in_pieces() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		r.map.holding[107] = 555;
		char[] adu = support::hx("00 09 00 00 00 06 01 03 00 6B 00 01");
		foreach (i, b : adu)
		{
			assert(r.conn.feed(adu[i:1])!! == 1);
			assert((r.conn.output().len > 0) == (i == adu.len - 1), "answer only after the last byte (%d)", i);
		}
		support::assert_bytes(r.take(), "03 02 02 2B");
		assert(r.last_tid == 9);
	};
}

// ---- limits lowered in the config ----

fn void test_lowered_limits() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		r.cfg.max_read_regs = 50;
		r.cfg.max_read_bits = 16;
		r.cfg.max_write_regs = 2;
		r.cfg.max_write_bits = 8;
		assert(r.call("03 00 00 00 32").len == 2 + 100);                                        // 50 registers
		support::assert_bytes(r.call("03 00 00 00 33"), "83 03");                               // 51
		support::assert_bytes(r.call("04 00 00 00 33"), "84 03");
		assert(r.call("01 00 00 00 10").len == 4);                                              // 16 coils
		support::assert_bytes(r.call("01 00 00 00 11"), "81 03");
		support::assert_bytes(r.call("02 00 00 00 11"), "82 03");
		support::assert_bytes(r.call("10 00 00 00 02 04 00 01 00 02"), "10 00 00 00 02");
		support::assert_bytes(r.call("10 00 00 00 03 06 00 01 00 02 00 03"), "90 03");
		support::assert_bytes(r.call("0F 00 00 00 08 01 FF"), "0F 00 00 00 08");
		support::assert_bytes(r.call("0F 00 00 00 09 02 FF 01"), "8F 03");
		assert(r.map.holding[2] == 0);
		// a lowered limit is judged before the address range
		support::assert_bytes(r.call("03 FF FF 00 33"), "83 03");
	};
}

// ---- read-only map ----

fn void test_read_only_map() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		r.map.read_only = true;
		r.map.holding[1] = 42;
		support::assert_bytes(r.call("05 00 01 FF 00"), "85 01");
		support::assert_bytes(r.call("06 00 01 00 03"), "86 01");
		support::assert_bytes(r.call("0F 00 00 00 08 01 FF"), "8F 01");
		support::assert_bytes(r.call("10 00 00 00 01 02 00 05"), "90 01");
		// the refusal comes before any range check
		support::assert_bytes(r.call("10 FF FF 00 02 04 00 01 00 02"), "90 01");
		support::assert_bytes(r.call("10 00 00 00 00 00"), "90 01");
		assert(r.map.holding[1] == 42 && !r.map.coils[1]);
		// reads still work
		support::assert_bytes(r.call("03 00 01 00 01"), "03 02 00 2A");
	};
}

// ---- a model that answers with its own exceptions ----

struct BusyModel (DataModel)
{
	int calls;
}

fn bool BusyModel.writable(&self, char unit) @dynamic => true;

fn ExceptionCode BusyModel.check_range(&self, char unit, Table table, ushort addr, ushort qty) @dynamic
{
	return ExceptionCode.NONE;
}

fn ExceptionCode BusyModel.read_coils(&self, char unit, ushort addr, bool[] out) @dynamic
{
	self.calls++;
	return ExceptionCode.SERVER_DEVICE_BUSY;
}

fn ExceptionCode BusyModel.read_discrete_inputs(&self, char unit, ushort addr, bool[] out) @dynamic => ExceptionCode.SERVER_DEVICE_FAILURE;
fn ExceptionCode BusyModel.read_holding(&self, char unit, ushort addr, ushort[] out) @dynamic => ExceptionCode.SERVER_DEVICE_FAILURE;
fn ExceptionCode BusyModel.read_input(&self, char unit, ushort addr, ushort[] out) @dynamic => ExceptionCode.NONE;
fn ExceptionCode BusyModel.write_coils(&self, char unit, ushort addr, bool[] values) @dynamic => ExceptionCode.MEMORY_PARITY_ERROR;
fn ExceptionCode BusyModel.write_holding(&self, char unit, ushort addr, ushort[] values) @dynamic => ExceptionCode.ACKNOWLEDGE;

fn void test_model_exceptions_are_passed_on() @test
{
	@pool()
	{
		BusyModel m;
		ServerConfig cfg = { .accept_any_unit = true };
		ServerConn c;
		c.init(&cfg, (DataModel)&m, mem)!!;
		defer c.free();
		char[300] adu;
		String[] reqs = { "01 00 00 00 01", "02 00 00 00 01", "03 00 00 00 01", "05 00 00 FF 00", "06 00 00 00 01", "0F 00 00 00 01 01 01", "10 00 00 00 01 02 00 01" };
		String[] want = { "81 06", "82 04", "83 04", "85 08", "86 05", "8F 08", "90 05" };
		foreach (i, q : reqs)
		{
			usz n = frame::mbap_encode(1, 1, support::hx(q), &adu)!!;
			assert(c.feed(adu[:n])!! == n);
			char[] o = c.output();
			support::assert_bytes(o[7..], want[i], q);
			c.consume_output(o.len);
		}
		assert(m.calls == 1);
	};
}

// ---- setup, framing errors ----

fn void test_init_checks() @test
{
	RegisterMap map;
	map.init(mem, 1, 1, 1, 1)!!;
	defer map.free();
	ServerConfig cfg = { .accept_any_unit = true, .output_size = 259 };
	ServerConn c;
	assert(@catch(c.init(&cfg, (DataModel)&map, mem)) == modbus::BUFFER_TOO_SMALL);
	cfg.output_size = 260;
	c.init(&cfg, (DataModel)&map, mem)!!;
	c.free();
}

fn void test_broken_framing_closes() @test
{
	@pool()
	{
		Rig r;
		r.setup();
		defer r.teardown();
		assert(@catch(r.conn.feed(support::hx("00 01 00 01 00 06 01 03 00 00 00 01"))) == modbus::BAD_PROTOCOL_ID);
		assert(@catch(r.conn.feed(support::hx("00"))) == modbus::CLOSED);
		Rig s;
		s.setup();
		defer s.teardown();
		assert(@catch(s.conn.feed(support::hx("00 01 00 00 00 01 01"))) == modbus::BAD_LENGTH);
	};
}

// ---- register map on its own ----

fn void test_register_map_ranges() @test
{
	RegisterMap m;
	m.init(mem, 10, 20, 30, 40)!!;
	defer m.free();
	assert(m.check_range(1, Table.COILS, 0, 10) == ExceptionCode.NONE);
	assert(m.check_range(1, Table.COILS, 1, 10) == ExceptionCode.ILLEGAL_DATA_ADDRESS);
	assert(m.check_range(1, Table.DISCRETE_INPUTS, 19, 1) == ExceptionCode.NONE);
	assert(m.check_range(1, Table.DISCRETE_INPUTS, 20, 1) == ExceptionCode.ILLEGAL_DATA_ADDRESS);
	assert(m.check_range(1, Table.HOLDING_REGISTERS, 29, 2) == ExceptionCode.ILLEGAL_DATA_ADDRESS);
	assert(m.check_range(1, Table.INPUT_REGISTERS, 0xFFFF, 1) == ExceptionCode.ILLEGAL_DATA_ADDRESS);
	assert(m.writable(1));
	ushort[2] w = { 1, 2 };
	assert(m.write_holding(1, 29, &w) == ExceptionCode.ILLEGAL_DATA_ADDRESS);
	assert(m.holding[29] == 0);                           // nothing written when the range does not fit
	assert(m.write_holding(1, 28, &w) == ExceptionCode.NONE);
	assert(m.holding[28] == 1 && m.holding[29] == 2);
	RegisterMap empty;
	empty.init(mem, 0, 0, 0, 0)!!;
	assert(empty.check_range(1, Table.COILS, 0, 1) == ExceptionCode.ILLEGAL_DATA_ADDRESS);
	empty.free();
}

// ---- random input ----

struct Rng
{
	uint state;
}

fn uint Rng.next(&self)
{
	self.state = self.state * 1664525 + 1013904223;
	return self.state >> 8;
}

fn void test_random_bytes_into_the_server() @test
{
	Rng rng = { .state = 31 };
	Rig r;
	r.setup(64, 64, 64, 64);
	defer r.teardown();
	char[40] chunk;
	usz total = 0;
	while (total < 10000)
	{
		usz n = (usz)(1 + rng.next() % 40);
		for (usz i = 0; i < n; i++) chunk[i] = (char)rng.next();
		usz taken;
		if (catch f = r.conn.feed(chunk[:n]))
		{
			r.teardown();
			r.setup(64, 64, 64, 64);
			continue;
		}
		taken = n;
		total += taken;
		r.conn.consume_output(r.conn.output().len);
	}
}

fn void test_random_requests_in_valid_frames() @test
{
	Rng rng = { .state = 77 };
	Rig r;
	r.setup(64, 64, 64, 64);
	defer r.teardown();
	for (int round = 0; round < 3000; round++)
	{
		usz plen = (usz)(1 + rng.next() % 40);
		char[64] pdu;
		for (usz i = 0; i < plen; i++) pdu[i] = (char)rng.next();
		if (rng.next() % 4 != 0) pdu[0] = (char)(1 + rng.next() % 6);
		char[] answer = r.call_bytes(pdu[:plen], 1, (ushort)round);
		if (pdu[0] < 0x80)
		{
			assert(answer.len >= 2, "an answer for fc %02x", pdu[0]);
			assert((answer[0] & 0x7F) == pdu[0], "answer function");
			if (answer[0] >= 0x80) assert(answer.len == 2);
		}
		else
		{
			assert(answer.len == 0);
		}
	}
}

// A failing allocation in the middle must not leak the tables allocated before it.
fn void test_register_map_init_failure_releases_tables() @test
{
	support::LimitedAllocator a = { .allowed = 2 };         // coils and discrete inputs succeed, holding fails
	RegisterMap m;
	assert(!@ok(m.init(&a, 10, 10, 1000, 10)));
	assert(a.live == 0, "the tables of a failed init were not released (%d live)", a.live);
	support::LimitedAllocator enough = { .allowed = 4 };
	m.init(&enough, 10, 10, 10, 10)!!;
	assert(enough.live == 4);
	m.free();
	assert(enough.live == 0);
}
