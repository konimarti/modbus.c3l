module modbus::rtu_stream_test;

import std::core::mem;
import std::time;
import modbus;
import modbus::client;
import modbus::frame;
import modbus::pdu;
import modbus::rtu_stream;
import modbus::server;
import modbus::support;
import modbus::transport;

// A transport-shaped double with its own faults (same names as every library uses).
faultdef TIMEOUT, CLOSED;

// Two byte queues, one per side. A write pushes one burst to the other side. After the last byte of a burst the
// reader sees one TIMEOUT: the silence that ends an RTU frame. Bursts pushed with gap_after = false run together.
struct Line
{
	char[2048][2] data;
	usz[2] len;
	usz[32][2] burst;          // burst lengths, in order
	bool[32][2] gap_after;
	usz[2] bursts;
	bool[2] silent_next;
	bool[2] closed;
}

fn void Line.push(&self, usz to, char[] bytes, bool gap_after = true)
{
	mem::copy(&self.data[to][self.len[to]], bytes.ptr, (sz)bytes.len);
	self.len[to] += bytes.len;
	self.burst[to][self.bursts[to]] = bytes.len;
	self.gap_after[to][self.bursts[to]] = gap_after;
	self.bursts[to]++;
}

fn usz? Line.take(&self, usz side, char[] buf)
{
	if (self.silent_next[side])
	{
		self.silent_next[side] = false;
		return TIMEOUT~;
	}
	if (self.bursts[side] == 0) return self.closed[side] ? CLOSED~ : TIMEOUT~;
	usz n = self.burst[side][0] < buf.len ? self.burst[side][0] : buf.len;
	mem::copy(buf.ptr, &self.data[side][0], (sz)n);
	mem::move(&self.data[side][0], &self.data[side][n], (sz)(self.len[side] - n));
	self.len[side] -= n;
	self.burst[side][0] -= n;
	if (self.burst[side][0] == 0)
	{
		bool gap = self.gap_after[side][0];
		for (usz i = 1; i < self.bursts[side]; i++)
		{
			self.burst[side][i - 1] = self.burst[side][i];
			self.gap_after[side][i - 1] = self.gap_after[side][i];
		}
		self.bursts[side]--;
		self.silent_next[side] = gap;
	}
	return n;
}

struct End
{
	Line* line;
	usz side;
	char[256] last_out;      // the last frame written by this side
	usz last_len;
	char[64] inject;         // bytes pushed back to this side right after each write (a damaged answer)
	usz inject_len;
	// when set, every write also gives this device a turn (single-threaded request/answer)
	ServerConfig* device_config;
	DataModel device_model;
	RtuStream* device_stream;
}

fn usz? End.read(&self, char[] buf, Duration timeout) @dynamic
{
	return self.line.take(self.side, buf);
}

fn void? End.write(&self, char[] data, Duration timeout) @dynamic
{
	if (self.line.closed[1 - self.side]) return CLOSED~;
	mem::copy(&self.last_out[0], data.ptr, (sz)data.len);
	self.last_len = data.len;
	self.line.push(1 - self.side, data);
	if (self.inject_len > 0) self.line.push(self.side, self.inject[:self.inject_len]);
	if (self.device_stream)
	{
		rtu_stream::serve_rtu_once(self.device_stream, self.device_config, self.device_model, time::ms(1))!!;
	}
}

fn void? End.close(&self) @dynamic
{
	self.line.closed[self.side] = true;
}

long ticks = 0;

fn Clock tick_clock()
{
	ticks += 1000000;               // every look at the clock is 1 ms later
	return (Clock)ticks;
}

// A client on side 0 and a device (register map, unit any) on side 1 that answers right after every request.
struct Bench
{
	Line line;
	End client_end;
	End device_end;
	RtuStream device_stream;
	RegisterMap map;
	ServerConfig cfg;
	RtuClient client;
}

fn void Bench.setup(&self, bool allow_write = true)
{
	self.map.init(mem, 400, 100, 400, 100)!!;
	self.cfg.accept_any_unit = true;
	self.cfg.allow_diagnostics = true;
	self.cfg.conformity_level = 1;
	self.cfg.server_id = support::hx("01 FF");
	self.client_end = { .line = &self.line, .side = 0 };
	self.device_end = { .line = &self.line, .side = 1 };
	self.device_stream.init((Transport)&self.device_end, time::ms(1));
	self.client_end.device_stream = &self.device_stream;
	self.client_end.device_config = &self.cfg;
	self.client_end.device_model = (DataModel)&self.map;
	ClientConfig k = client::default_config();
	k.allow_write = allow_write;
	k.timeout = time::ms(30);
	self.client.init((Transport)&self.client_end, k, time::ms(1), mem)!!;
	self.client.clock = &tick_clock;
}

fn void Bench.teardown(&self)
{
	self.client.free();
	self.map.free();
}

fn void assert_written(End* e, String hex, String name)
{
	support::assert_bytes(e.last_out[:e.last_len], hex, name);
}

// ---- framing by silence ----

fn void test_frame_ends_at_silence() @test
{
	@pool()
	{
		Line line;
		End e = { .line = &line, .side = 0 };
		RtuStream s;
		s.init((Transport)&e, time::ms(1));
		char[256] buf;
		line.push(0, support::hx("01 03 00 00 00 0A C5 CD"));
		assert(s.read_frame(&buf, time::ms(10))!! == 8);
		support::assert_bytes(buf[:8], "01 03 00 00 00 0A C5 CD");
		// nothing more: the wait times out
		assert(@catch(s.read_frame(&buf, time::ms(10))) == modbus::TIMEOUT);
	};
}

fn void test_frame_in_pieces_without_a_gap() @test
{
	@pool()
	{
		Line line;
		End e = { .line = &line, .side = 0 };
		RtuStream s;
		s.init((Transport)&e, time::ms(1));
		char[256] buf;
		// the bytes of one frame arrive in three pieces with no silence between them
		line.push(0, support::hx("01 03 06"), false);
		line.push(0, support::hx("02 2B 00 00"), false);
		line.push(0, support::hx("00 64 05 7A"));
		assert(s.read_frame(&buf, time::ms(10))!! == 11);
		support::assert_bytes(buf[:11], "01 03 06 02 2B 00 00 00 64 05 7A");
	};
}

fn void test_two_frames_with_silence_between() @test
{
	@pool()
	{
		Line line;
		End e = { .line = &line, .side = 0 };
		RtuStream s;
		s.init((Transport)&e, time::ms(1));
		char[256] buf;
		line.push(0, support::hx("01 81 02 C1 91"));
		line.push(0, support::hx("01 83 02 C0 F1"));
		assert(s.read_frame(&buf, time::ms(10))!! == 5);
		support::assert_bytes(buf[:5], "01 81 02 C1 91");
		assert(s.read_frame(&buf, time::ms(10))!! == 5);
		support::assert_bytes(buf[:5], "01 83 02 C0 F1");
	};
}

fn void test_over_long_frame_is_refused() @test
{
	@pool()
	{
		Line line;
		End e = { .line = &line, .side = 0 };
		RtuStream s;
		s.init((Transport)&e, time::ms(1));
		char[256] buf;
		char[400] noise;
		line.push(0, &noise);
		assert(@catch(s.read_frame(&buf, time::ms(10))) == modbus::BAD_LENGTH);
		// the line is quiet again: the next frame is read normally
		line.push(0, support::hx("01 11 C0 2C"));
		assert(s.read_frame(&buf, time::ms(10))!! == 4);
	};
}

fn void test_closed_stream() @test
{
	@pool()
	{
		Line line;
		End e = { .line = &line, .side = 0 };
		RtuStream s;
		s.init((Transport)&e, time::ms(1));
		char[256] buf;
		line.push(0, support::hx("01 11 C0 2C"));
		line.closed[0] = true;
		// the bytes that came before the end are delivered, then the end is reported
		assert(s.read_frame(&buf, time::ms(10))!! == 4);
		assert(@catch(s.read_frame(&buf, time::ms(10))) == modbus::CLOSED);
	};
}

fn void test_write_frame_discards_stale_bytes() @test
{
	@pool()
	{
		Line line;
		End e = { .line = &line, .side = 0 };
		RtuStream s;
		s.init((Transport)&e, time::ms(1));
		line.push(0, support::hx("01 03 02 00 07 F9 A5"));     // a late answer still on the line
		s.write_frame(support::hx("01 11 C0 2C"), time::ms(10))!!;
		assert(line.bursts[0] == 0 && line.len[0] == 0, "the stale bytes are gone");
		assert(line.len[1] == 4);
	};
}

// ---- RTU vectors end to end: client -> stream -> server -> stream -> client ----

fn void test_read_vectors_end_to_end() @test
{
	@pool()
	{
		Bench b;
		b.setup();
		defer b.teardown();
		ExceptionCode exc;
		// R1: ten holding registers from 0
		Request r1 = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 10);
		Response rsp = b.client.call(&r1, &exc)!!;
		assert_written(&b.client_end, "01 03 00 00 00 0A C5 CD", "R1");
		assert(rsp.reg_count() == 10);
		// R3 and its answer R4 (unit 0x11)
		b.map.holding[107] = 0xAE41;
		b.map.holding[108] = 0x5652;
		b.map.holding[109] = 0x4340;
		Request r3 = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 107, 3);
		rsp = b.client.call(&r3, &exc, 0x11)!!;
		assert_written(&b.client_end, "11 03 00 6B 00 03 76 87", "R3");
		support::assert_bytes(b.device_end.last_out[:b.device_end.last_len], "11 03 06 AE 41 56 52 43 40 49 AD", "R4");
		assert(rsp.reg(0) == 0xAE41 && rsp.reg(2) == 0x4340);
		// R12: the answer to a read of registers 1 to 3
		b.map.holding[1] = 555;
		b.map.holding[3] = 100;
		Request r12 = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 1, 3);
		b.client.call(&r12, &exc)!!;
		support::assert_bytes(b.device_end.last_out[:b.device_end.last_len], "01 03 06 02 2B 00 00 00 64 05 7A", "R12");
		// R2: one input register
		b.map.input[0] = 0xFFFF;
		Request r2 = pdu::read_request(Fc.READ_INPUT_REGISTERS, 0, 1);
		b.client.call(&r2, &exc)!!;
		support::assert_bytes(b.device_end.last_out[:b.device_end.last_len], "01 04 02 FF FF B8 80", "R2");
		// R5: coils 19 to 37
		Request r5 = pdu::read_request(Fc.READ_COILS, 19, 19);
		rsp = b.client.call(&r5, &exc)!!;
		assert_written(&b.client_end, "01 01 00 13 00 13 8C 02", "R5");
		assert(rsp.qty == 19);
	};
}

fn void test_exception_vectors_end_to_end() @test
{
	@pool()
	{
		Bench b;
		b.setup();
		defer b.teardown();
		ExceptionCode exc;
		Request r6 = pdu::read_request(Fc.READ_COILS, 0xFFFF, 1);
		assert(@catch(b.client.call(&r6, &exc)) == modbus::REMOTE_EXCEPTION);
		assert(exc == ExceptionCode.ILLEGAL_DATA_ADDRESS);
		support::assert_bytes(b.device_end.last_out[:b.device_end.last_len], "01 81 02 C1 91", "R6");
		Request r7 = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0xFFFF, 1);
		assert(@catch(b.client.call(&r7, &exc)) == modbus::REMOTE_EXCEPTION);
		support::assert_bytes(b.device_end.last_out[:b.device_end.last_len], "01 83 02 C0 F1", "R7");
		// the connection is fine afterwards
		Request ok = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		b.client.call(&ok, &exc)!!;
	};
}

fn void test_write_vectors_end_to_end() @test
{
	@pool()
	{
		Bench b;
		b.setup();
		defer b.teardown();
		ExceptionCode exc;
		Request r8 = pdu::write_single_coil(172, true);
		b.client.call(&r8, &exc)!!;
		assert_written(&b.client_end, "01 05 00 AC FF 00 4C 1B", "R8");
		support::assert_bytes(b.device_end.last_out[:b.device_end.last_len], "01 05 00 AC FF 00 4C 1B");
		assert(b.map.coils[172]);
		Request r9 = pdu::write_single_register(1, 3);
		b.client.call(&r9, &exc)!!;
		assert_written(&b.client_end, "01 06 00 01 00 03 98 0B", "R9");
		assert(b.map.holding[1] == 3);
		char[16] scratch;
		ushort[2] regs = { 0x000A, 0x0102 };
		Request r10 = pdu::write_multiple_registers(1, &regs, &scratch)!!;
		b.client.call(&r10, &exc)!!;
		assert_written(&b.client_end, "01 10 00 01 00 02 04 00 0A 01 02 92 30", "R10");
		assert(b.map.holding[1] == 0x000A && b.map.holding[2] == 0x0102);
		bool[10] bits = { true, false, true, true, false, false, true, true, true, false };
		Request r11 = pdu::write_multiple_coils(19, &bits, &scratch)!!;
		b.client.call(&r11, &exc)!!;
		assert_written(&b.client_end, "01 0F 00 13 00 0A 02 CD 01 72 CB", "R11");
		assert(b.map.coils[19] && b.map.coils[21] && !b.map.coils[20]);
		ushort[3] w = { 0x1234, 0x5678, 0x9ABC };
		char[16] sc2;
		Request r15 = pdu::read_write_registers(3, 6, 14, &w, &sc2)!!;
		b.client.call(&r15, &exc)!!;
		assert_written(&b.client_end, "01 17 00 03 00 06 00 0E 00 03 06 12 34 56 78 9A BC 6A C3", "R15");
		assert(b.map.holding[14] == 0x1234);
	};
}

fn void test_device_and_server_id_end_to_end() @test
{
	@pool()
	{
		Bench b;
		pdu::DeviceObject[3] objs = { { 0, "ACME" }, { 1, "X1" }, { 2, "1.0" } };
		b.setup();
		b.cfg.device_objects = &objs;
		defer b.teardown();
		ExceptionCode exc;
		Request r13 = pdu::read_device_id(1, 0);
		Response rsp = b.client.call(&r13, &exc)!!;
		assert_written(&b.client_end, "01 2B 0E 01 00 70 77", "R13");
		assert(rsp.object_count == 3);
		Request r14 = { .fc = (char)Fc.REPORT_SERVER_ID };
		rsp = b.client.call(&r14, &exc)!!;
		assert_written(&b.client_end, "01 11 C0 2C", "R14");
		support::assert_bytes(rsp.data, "01 FF");
	};
}

fn void test_broadcast_end_to_end() @test
{
	@pool()
	{
		Bench b;
		b.setup();
		defer b.teardown();
		Request w = pdu::write_single_register(1, 3);
		b.client.broadcast(&w)!!;
		assert_written(&b.client_end, "00 06 00 01 00 03 99 DA", "R16");
		assert(b.map.holding[1] == 3, "the device executed the broadcast");
		assert(b.line.bursts[0] == 0, "and answered nothing");
		// a read cannot be broadcast, and call() refuses unit 0
		ExceptionCode exc;
		Request rd = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		assert(@catch(b.client.call(&rd, &exc, 0)) == modbus::BAD_VALUE);
		assert(@catch(b.client.broadcast(&rd)) == modbus::BAD_VALUE);
	};
}

// ---- bad frames ----

fn void test_bad_crc_request_is_ignored_by_the_device() @test
{
	@pool()
	{
		Bench b;
		b.setup();
		defer b.teardown();
		// XR1: the CRC bytes swapped; XR2: one bit flipped. Nothing is executed, nothing is answered.
		b.line.push(1, support::hx("01 06 00 01 00 03 0B 98"));
		b.line.push(1, support::hx("01 06 00 01 00 03 98 0A"));
		rtu_stream::serve_rtu_once(&b.device_stream, &b.cfg, (DataModel)&b.map, time::ms(5))!!;
		rtu_stream::serve_rtu_once(&b.device_stream, &b.cfg, (DataModel)&b.map, time::ms(5))!!;
		assert(b.map.holding[1] == 0);
		assert(b.line.bursts[0] == 0);
		// the same request with a good CRC is served
		b.line.push(1, support::hx("01 06 00 01 00 03 98 0B"));
		rtu_stream::serve_rtu_once(&b.device_stream, &b.cfg, (DataModel)&b.map, time::ms(5))!!;
		assert(b.map.holding[1] == 3 && b.line.bursts[0] == 1);
	};
}

fn void test_bad_crc_answer_makes_the_request_time_out() @test
{
	@pool()
	{
		Bench b;
		b.setup();
		b.client_end.device_stream = null;                 // no device behind the client: the test plays it
		defer b.teardown();
		// the answer arrives right after the request, with the last CRC byte wrong
		char[] damaged = support::hx("01 03 06 02 2B 00 00 00 64 05 7B");
		mem::copy(&b.client_end.inject[0], damaged.ptr, (sz)damaged.len);
		b.client_end.inject_len = damaged.len;
		ExceptionCode exc;
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 1, 3);
		assert(@catch(b.client.call(&r, &exc)) == modbus::TIMEOUT);
		// the same answer with a good CRC completes the request
		char[] good = support::hx("01 03 06 02 2B 00 00 00 64 05 7A");
		mem::copy(&b.client_end.inject[0], good.ptr, (sz)good.len);
		Response rsp = b.client.call(&r, &exc)!!;
		assert(rsp.reg(0) == 555 && rsp.reg(2) == 100);
	};
}

fn void test_device_ignores_other_addresses() @test
{
	@pool()
	{
		Bench b;
		b.setup();
		defer b.teardown();
		b.cfg.accept_any_unit = false;
		char[1] mine = { 7 };
		b.cfg.units = &mine;
		ExceptionCode exc;
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		assert(@catch(b.client.call(&r, &exc, 1)) == modbus::TIMEOUT);        // not our address: no answer
		assert(@catch(b.client.call(&r, &exc, 249)) == modbus::TIMEOUT);      // reserved address
		b.client.call(&r, &exc, 7)!!;
	};
}

fn void test_late_answer_cannot_complete_the_next_request() @test
{
	@pool()
	{
		Bench b;
		b.setup();
		b.client_end.device_stream = null;
		defer b.teardown();
		ExceptionCode exc;
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		assert(@catch(b.client.call(&r, &exc)) == modbus::TIMEOUT);
		// the answer to the first request arrives late, before the second request is sent
		char[16] stale;
		usz sn = frame::rtu_encode(1, support::hx("03 02 00 07"), &stale)!!;
		b.line.push(0, stale[:sn]);
		// the second call flushes it; its own answer comes from the device after the request
		b.client_end.device_stream = &b.device_stream;
		b.map.holding[0] = 9;
		Response rsp = b.client.call(&r, &exc)!!;
		assert(rsp.reg(0) == 9, "the late answer (7) was discarded");
	};
}

fn void test_write_guard_over_rtu() @test
{
	@pool()
	{
		Bench b;
		b.setup(false);
		defer b.teardown();
		ExceptionCode exc;
		Request w = pdu::write_single_register(1, 3);
		assert(@catch(b.client.call(&w, &exc)) == modbus::WRITE_NOT_ALLOWED);
		assert(@catch(b.client.broadcast(&w)) == modbus::WRITE_NOT_ALLOWED);
		assert(b.line.len[1] == 0, "nothing was sent");
		assert(b.map.holding[1] == 0);
	};
}

fn void test_closed_line_fails_the_call() @test
{
	@pool()
	{
		Bench b;
		b.setup();
		b.client_end.device_stream = null;
		defer b.teardown();
		b.line.closed[1] = true;
		ExceptionCode exc;
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		assert(@catch(b.client.call(&r, &exc)) == modbus::CLOSED);
	};
}

fn void test_device_step_reports_a_closed_line() @test
{
	@pool()
	{
		Bench b;
		b.setup();
		defer b.teardown();
		// nothing arrives: the step returns quietly
		rtu_stream::serve_rtu_once(&b.device_stream, &b.cfg, (DataModel)&b.map, time::ms(5))!!;
		b.line.closed[1] = true;
		assert(@catch(rtu_stream::serve_rtu_once(&b.device_stream, &b.cfg, (DataModel)&b.map, time::ms(5))) == modbus::CLOSED);
	};
}

// A CRC-valid answer whose body is wrong is a real (wrong) answer, not a lost one: the fault is reported,
// not a closed connection.
fn void test_valid_crc_bad_body_is_reported() @test
{
	@pool()
	{
		Bench b;
		b.setup();
		b.client_end.device_stream = null;
		defer b.teardown();
		char[16] answer;
		// four bytes of data for a read of three registers
		usz n = frame::rtu_encode(1, support::hx("03 04 02 2B 00 00"), &answer)!!;
		mem::copy(&b.client_end.inject[0], &answer[0], (sz)n);
		b.client_end.inject_len = n;
		ExceptionCode exc;
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 1, 3);
		assert(@catch(b.client.call(&r, &exc)) == modbus::BAD_BYTE_COUNT);
		// the client is still usable
		b.client_end.inject_len = 0;
		b.client_end.device_stream = &b.device_stream;
		b.client.call(&r, &exc)!!;
	};
}

// A configured unit of 0 is the broadcast address: call() must not send a write there and then report a
// connection error.
fn void test_default_unit_zero_is_refused() @test
{
	@pool()
	{
		Bench b;
		b.setup();
		defer b.teardown();
		b.client.core.config.unit = 0;
		ExceptionCode exc;
		Request w = pdu::write_single_register(1, 3);
		assert(@catch(b.client.call(&w, &exc)) == modbus::BAD_VALUE);
		assert(b.line.len[1] == 0, "nothing was sent");
		assert(b.map.holding[1] == 0);
		// an explicit unit still works
		b.client.call(&w, &exc, 1)!!;
		assert(b.map.holding[1] == 3);
	};
}
