module modbus::tcp_test;

import std::core::mem;
import std::net;
import std::time;
import modbus;
import modbus::client;
import modbus::frame;
import modbus::pdu;
import modbus::server;
import modbus::support;
import modbus::tcp;
import modbus::transport;

// No threads: the server is stepped (serve_once) between the client's write and read, so every test is deterministic.

// ---- a server on a free port ----

struct Net
{
	RegisterMap map;
	ServerConfig cfg;
	TcpServer server;
	ushort port;
}

fn void Net.setup(&self)
{
	self.map.init(mem, 200, 10, 200, 10)!!;
	self.cfg.accept_any_unit = true;
	self.cfg.conformity_level = 1;
	TcpServerSocket l = std::net::tcp::listen("127.0.0.1", 0, 8, REUSEADDR)!!;
	self.port = l.local_port()!!;
	self.server.init(l, &self.cfg, (DataModel)&self.map, mem)!!;
}

fn void Net.teardown(&self)
{
	self.server.close();
	self.map.free();
}

fn void Net.step(&self, int rounds = 3)
{
	for (int i = 0; i < rounds; i++) self.server.serve_once(time::ms(20))!!;
}

fn void Net.connect(&self, TcpTransport* t)
{
	t.connect("127.0.0.1", self.port, time::sec(2))!!;
}

fn char[] read_all(TcpTransport* t, usz want)
{
	char[] got = mem::temp_array(char, (sz)want);
	usz have = 0;
	while (have < want) have += t.read(got[have..], time::sec(2))!!;
	return got;
}

// ---- raw frames over a real socket (TV-M1 and its answer) ----

fn void test_raw_request_and_answer_over_a_socket() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		n.map.holding[107] = 0xAE41;
		n.map.holding[108] = 0x5652;
		n.map.holding[109] = 0x4340;
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		t.write(support::hx("00 01 00 00 00 06 11 03 00 6B 00 03"), time::sec(1))!!;           // TV-M1
		n.step();
		support::assert_bytes(read_all(&t, 15), "00 01 00 00 00 09 11 03 06 AE 41 56 52 43 40", "TV-M2");
		assert(n.server.connection_count() == 1);
	};
}

fn void test_two_clients_are_served() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		n.map.holding[0] = 0x1111;
		TcpTransport a;
		TcpTransport b;
		n.connect(&a);
		n.connect(&b);
		defer (void)a.close();
		defer (void)b.close();
		a.write(support::hx("00 01 00 00 00 06 01 03 00 00 00 01"), time::sec(1))!!;
		b.write(support::hx("00 07 00 00 00 06 01 06 00 01 00 05"), time::sec(1))!!;
		n.step(4);
		support::assert_bytes(read_all(&a, 11), "00 01 00 00 00 05 01 03 02 11 11");
		support::assert_bytes(read_all(&b, 12), "00 07 00 00 00 06 01 06 00 01 00 05");
		assert(n.map.holding[1] == 5);
		assert(n.server.connection_count() == 2);
	};
}

fn void test_requests_split_across_writes() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		char[] req = support::hx("00 09 00 00 00 06 01 03 00 00 00 01");
		for (usz i = 0; i < req.len; i++)
		{
			t.write(req[i:1], time::sec(1))!!;
			n.step(1);
		}
		n.step(2);
		support::assert_bytes(read_all(&t, 11), "00 09 00 00 00 05 01 03 02 00 00");
	};
}

// ---- connection handling ----

fn void test_connection_limit_of_eight() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		TcpTransport[9] clients;
		for (usz i = 0; i < 9; i++) n.connect(&clients[i]);
		n.step(12);
		assert(n.server.connection_count() == 8);
		// the ninth connection was accepted and closed at once
		char[8] buf;
		usz? r = clients[8].read(&buf, time::sec(1));
		assert(@catch(r) == modbus::CLOSED);
		// the others still work
		clients[0].write(support::hx("00 01 00 00 00 06 01 03 00 00 00 01"), time::sec(1))!!;
		n.step(2);
		assert(read_all(&clients[0], 11).len == 11);
		for (usz i = 0; i < 9; i++) (void)clients[i].close();
	};
}

fn void test_broken_framing_drops_the_connection() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		t.write(support::hx("00 01 00 01 00 06 01 03 00 00 00 01"), time::sec(1))!!;         // protocol id 1
		n.step(3);
		assert(n.server.connection_count() == 0);
		char[8] buf;
		assert(@catch(t.read(&buf, time::sec(1))) == modbus::CLOSED);
	};
}

fn void test_peer_close_frees_the_slot() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		TcpTransport t;
		n.connect(&t);
		n.step(2);
		assert(n.server.connection_count() == 1);
		t.close()!!;
		n.step(3);
		assert(n.server.connection_count() == 0);
	};
}

fn void test_serve_returns_when_stopped() @test
{
	Net n;
	n.setup();
	defer n.teardown();
	bool stop = true;
	n.server.serve(&stop)!!;
}

// ---- the transport on its own ----

fn void test_read_times_out_without_data() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		char[8] buf;
		assert(@catch(t.read(&buf, time::ms(20))) == modbus::TIMEOUT);
		assert(@catch(t.read(&buf, time::DURATION_ZERO)) == modbus::TIMEOUT);
		t.set_nodelay(true)!!;
	};
}

fn void test_close_is_idempotent() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		TcpTransport t;
		n.connect(&t);
		t.close()!!;
		t.close()!!;
		char[8] buf;
		assert(@catch(t.read(&buf, time::ms(10))) == modbus::CLOSED);
		assert(@catch(t.write(support::hx("00"), time::ms(10))) == modbus::CLOSED);
	};
}

fn void test_connect_to_a_closed_port_fails() @test
{
	TcpServerSocket l = std::net::tcp::listen("127.0.0.1", 0, 1)!!;
	ushort port = l.local_port()!!;
	(void)l.close();
	TcpTransport t;
	assert(!@ok(t.connect("127.0.0.1", port, time::sec(1))));
	assert(!t.open);
}

// ---- BlockingClient over sockets, the server stepped by the transport wrapper ----

// A transport that gives the server a turn before every read; mode 1: the peer never answers; mode 2: the peer
// sends half an answer and closes.
struct Stepper (Transport)
{
	TcpTransport* inner;
	Net* net;
	int mode;
	int writes;
	usz bytes;
}

fn usz? Stepper.read(&self, char[] buf, Duration timeout) @dynamic
{
	if (self.mode == 0) self.net.step(3);         // accept, read, answer
	return self.inner.read(buf, timeout);
}

fn void? Stepper.write(&self, char[] data, Duration timeout) @dynamic
{
	self.writes++;
	self.bytes += data.len;
	return self.inner.write(data, timeout);
}

fn void? Stepper.close(&self) @dynamic
{
	return self.inner.close();
}

fn void test_blocking_read() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		n.map.holding[107] = 555;
		n.map.holding[109] = 100;
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		Stepper s = { .inner = &t, .net = &n };
		BlockingClient bc;
		bc.init((Transport)&s, client::default_config(), mem)!!;
		defer bc.free();
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 107, 3);
		ExceptionCode exc;
		Response rsp = bc.call(&r, &exc)!!;
		assert(rsp.reg(0) == 555 && rsp.reg(1) == 0 && rsp.reg(2) == 100);
		// a second call on the same connection
		Request r2 = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 109, 1);
		rsp = bc.call(&r2, &exc)!!;
		assert(rsp.reg(0) == 100);
	};
}

fn void test_blocking_write_needs_allow_write() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		Stepper s = { .inner = &t, .net = &n };
		BlockingClient bc;
		bc.init((Transport)&s, client::default_config(), mem)!!;
		defer bc.free();
		Request w = pdu::write_single_register(3, 0x1234);
		ExceptionCode exc;
		assert(@catch(bc.call(&w, &exc)) == modbus::WRITE_NOT_ALLOWED);
		n.step(3);
		assert(s.writes == 0 && s.bytes == 0, "nothing was sent");
		assert(n.map.holding[3] == 0);
		// the guard is a config switch
		bc.core.config.allow_write = true;
		Response rsp = bc.call(&w, &exc)!!;
		assert(rsp.addr == 3 && rsp.value == 0x1234);
		assert(n.map.holding[3] == 0x1234);
		assert(s.writes == 1);
	};
}

fn void test_blocking_exception() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		Stepper s = { .inner = &t, .net = &n };
		BlockingClient bc;
		bc.init((Transport)&s, client::default_config(), mem)!!;
		defer bc.free();
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 1000, 1);
		ExceptionCode exc;
		assert(@catch(bc.call(&r, &exc)) == modbus::REMOTE_EXCEPTION);
		assert(exc == ExceptionCode.ILLEGAL_DATA_ADDRESS);
		// the connection is still good
		Request ok = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		bc.call(&ok, &exc)!!;
	};
}

fn void test_blocking_timeout_when_the_peer_is_silent() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		Stepper s = { .inner = &t, .net = &n, .mode = 1 };
		ClientConfig k = client::default_config();
		k.timeout = time::ms(40);
		BlockingClient bc;
		bc.init((Transport)&s, k, mem)!!;
		defer bc.free();
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		ExceptionCode exc;
		assert(@catch(bc.call(&r, &exc)) == modbus::TIMEOUT);
		// the connection survives a timeout: the late answer is skipped, the next call gets its own
		s.mode = 0;
		Response rsp = bc.call(&r, &exc)!!;
		assert(rsp.reg_count() == 1);
	};
}

// ---- a peer that closes in the middle of an answer ----

struct HalfPeer (Transport)
{
	TcpTransport* client;
	TcpTransport peer;
	bool done;
}

fn usz? HalfPeer.read(&self, char[] buf, Duration timeout) @dynamic
{
	if (!self.done)
	{
		self.done = true;
		char[64] req;
		self.peer.read(&req, time::sec(1))!!;
		self.peer.write(support::hx("00 01 00 00 00 09 01 03"), time::sec(1))!!;      // 8 of 15 bytes
		self.peer.close()!!;
	}
	return self.client.read(buf, timeout);
}

fn void? HalfPeer.write(&self, char[] data, Duration timeout) @dynamic
{
	return self.client.write(data, timeout);
}

fn void? HalfPeer.close(&self) @dynamic
{
	return self.client.close();
}

fn void test_peer_closes_in_the_middle_of_an_answer() @test
{
	@pool()
	{
		TcpServerSocket l = std::net::tcp::listen("127.0.0.1", 0, 2)!!;
		ushort port = l.local_port()!!;
		defer (void)l.close();
		TcpTransport t;
		t.connect("127.0.0.1", port, time::sec(1))!!;
		defer (void)t.close();
		HalfPeer h = { .client = &t };
		h.peer.adopt(std::net::tcp::accept(&l)!!);
		BlockingClient bc;
		bc.init((Transport)&h, client::default_config(), mem)!!;
		defer bc.free();
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 3);
		ExceptionCode exc;
		assert(@catch(bc.call(&r, &exc)) == modbus::CLOSED);
		// the client is broken: the next call says so at once
		assert(@catch(bc.call(&r, &exc)) == modbus::CLOSED);
	};
}

// ---- a foreign transport (same shape as tls.c3l's TlsTransport) with its own faults ----

faultdef TIMEOUT, CLOSED;

struct Script
{
	char[1024] queue;
	usz queued;
	String[] replies;        // one per request: a PDU in hex ("" = no answer); "@..." = raw frame, sent as is
	usz next_reply;
	int writes;
	bool closed;
}

fn void Script.push(&self, char[] frame)
{
	mem::copy(&self.queue[self.queued], frame.ptr, (sz)frame.len);
	self.queued += frame.len;
}

fn usz? Script.read(&self, char[] buf, Duration timeout) @dynamic
{
	if (self.queued == 0) return TIMEOUT~;
	usz n = self.queued < buf.len ? self.queued : buf.len;
	mem::copy(buf.ptr, &self.queue[0], (sz)n);
	mem::move(&self.queue[0], &self.queue[n], (sz)(self.queued - n));
	self.queued -= n;
	return n;
}

fn void? Script.write(&self, char[] data, Duration timeout) @dynamic
{
	self.writes++;
	if (self.next_reply >= self.replies.len) return;
	String reply = self.replies[self.next_reply++];
	if (reply.len == 0) return;
	if (reply[0] == '@')
	{
		self.push(support::hx(reply[1..]));
		return;
	}
	ushort tid = (ushort)(((ushort)data[0] << 8) | data[1]);
	char[260] frame;
	usz n = frame::mbap_encode(tid, data[6], support::hx(reply), &frame)!!;
	self.push(frame[:n]);
}

fn void? Script.close(&self) @dynamic
{
	self.closed = true;
}

long fake_now = 0;

fn Clock fake_clock()
{
	fake_now += 1000000;               // every look at the clock is 1 ms later
	return (Clock)fake_now;
}

fn BlockingClient* new_client(Script* s, usz timeout_ms = 50)
{
	BlockingClient* bc = mem::new(BlockingClient);
	ClientConfig k = client::default_config();
	k.timeout = time::ms((long)timeout_ms);
	bc.init((Transport)s, k, mem)!!;
	bc.clock = &fake_clock;
	return bc;
}

fn void release(BlockingClient* bc)
{
	bc.free();
	mem::free(bc);
}

fn void test_foreign_transport_through_the_cast() @test
{
	@pool()
	{
		String[1] replies = { "03 06 02 2B 00 00 00 64" };
		Script s = { .replies = &replies };
		BlockingClient* bc = new_client(&s);
		defer release(bc);
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 107, 3);
		ExceptionCode exc;
		Response rsp = bc.call(&r, &exc)!!;
		assert(rsp.reg(0) == 555 && rsp.reg(2) == 100);
		assert(s.writes == 1);
	};
}

fn void test_foreign_timeout_fault_is_recognised() @test
{
	@pool()
	{
		String[1] replies = { "" };                       // no answer
		Script s = { .replies = &replies };
		BlockingClient* bc = new_client(&s, 20);
		defer release(bc);
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		ExceptionCode exc;
		assert(@catch(bc.call(&r, &exc)) == modbus::TIMEOUT);
	};
}

fn void test_late_answer_is_skipped() @test
{
	@pool()
	{
		String[2] replies = { "", "03 02 00 09" };            // request 1: no answer; request 2: answered normally
		Script s = { .replies = &replies };
		BlockingClient* bc = new_client(&s, 20);
		defer release(bc);
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		ExceptionCode exc;
		assert(@catch(bc.call(&r, &exc)) == modbus::TIMEOUT);
		// the late answer of request 1 (tid 1) reaches the client before the answer of request 2
		s.push(support::hx("00 01 00 00 00 05 01 03 02 00 07"));
		Response rsp = bc.call(&r, &exc)!!;
		assert(rsp.reg(0) == 9, "the answer of the second request, not the late one");
	};
}

fn void test_write_failure_breaks_the_client() @test
{
	@pool()
	{
		String[1] replies = { "" };
		Script s = { .replies = &replies };
		BlockingClient* bc = new_client(&s);
		defer release(bc);
		bc.core.fail_all(modbus::CLOSED);
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		ExceptionCode exc;
		assert(@catch(bc.call(&r, &exc)) == modbus::CLOSED);
		assert(s.writes == 0);
	};
}

// ---- device identification loop (Y8 and friends) ----

fn void test_device_id_loop_follows_more_follows() @test
{
	@pool()
	{
		String[3] replies = {
			"2B 0E 01 01 FF 01 02 00 02 41 42 01 01 43",            // objects 0 "AB", 1 "C"; more follows, continue at 1
			"2B 0E 01 01 FF 02 01 01 02 44 45",
			"2B 0E 01 01 00 00 01 02 01 46",
		};
		Script s = { .replies = &replies };
		BlockingClient* bc = new_client(&s);
		defer release(bc);
		pdu::DeviceObject[8] objs;
		char[64] text;
		// round 1 asks from object 0 and is told to continue at 1, which is progress (1 > 0)
		usz n = bc.read_device_id_all(1, 16, &objs, &text)!!;
		assert(n == 4, "objects: %d", n);
		assert(s.writes == 3);
		assert(objs[0].id == 0 && objs[0].value == "AB");
		assert(objs[1].id == 1 && objs[1].value == "C");
		assert(objs[2].id == 1 && objs[2].value == "DE");
		assert(objs[3].id == 2 && objs[3].value == "F");
	};
}

fn void test_device_id_without_progress_is_a_mismatch() @test
{
	@pool()
	{
		// Y8: more follows, next object id 0: the same request again would loop for ever
		String[2] replies = { "2B 0E 01 01 FF 00 01 00 02 41 42", "2B 0E 01 01 FF 00 01 00 02 41 42" };
		Script s = { .replies = &replies };
		BlockingClient* bc = new_client(&s);
		defer release(bc);
		pdu::DeviceObject[8] objs;
		char[64] text;
		assert(@catch(bc.read_device_id_all(1, 16, &objs, &text)) == modbus::MISMATCH);
		assert(s.writes == 1, "stops after the first answer");
	};
}

fn void test_device_id_round_cap() @test
{
	@pool()
	{
		// every answer moves forward by one object: only the round cap ends it
		String[6] replies = {
			"2B 0E 01 01 FF 01 01 00 01 41",
			"2B 0E 01 01 FF 02 01 01 01 42",
			"2B 0E 01 01 FF 03 01 02 01 43",
			"2B 0E 01 01 FF 04 01 03 01 44",
			"2B 0E 01 01 FF 05 01 04 01 45",
			"2B 0E 01 01 00 00 01 05 01 46",
		};
		Script s = { .replies = &replies };
		BlockingClient* bc = new_client(&s);
		defer release(bc);
		pdu::DeviceObject[8] objs;
		char[64] text;
		assert(@catch(bc.read_device_id_all(1, 3, &objs, &text)) == modbus::MISMATCH);
		assert(s.writes == 3);
	};
}

fn void test_device_id_buffers_too_small() @test
{
	@pool()
	{
		String[1] replies = { "2B 0E 01 01 00 00 02 00 02 41 42 01 02 43 44" };
		Script s = { .replies = &replies };
		BlockingClient* bc = new_client(&s);
		defer release(bc);
		pdu::DeviceObject[1] one;
		char[64] text;
		assert(@catch(bc.read_device_id_all(1, 16, &one, &text)) == modbus::BUFFER_TOO_SMALL);
		Script s2 = { .replies = &replies };
		BlockingClient* bc2 = new_client(&s2);
		defer release(bc2);
		pdu::DeviceObject[4] objs;
		char[3] short_text;
		assert(@catch(bc2.read_device_id_all(1, 16, &objs, &short_text)) == modbus::BUFFER_TOO_SMALL);
	};
}

fn void test_device_id_over_sockets() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		pdu::DeviceObject[3] objs = { { 0, "ACME" }, { 1, "X1" }, { 2, "1.0" } };
		n.cfg.device_objects = &objs;
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		Stepper s = { .inner = &t, .net = &n };
		BlockingClient bc;
		bc.init((Transport)&s, client::default_config(), mem)!!;
		defer bc.free();
		pdu::DeviceObject[8] got;
		char[64] text;
		usz count = bc.read_device_id_all(1, 16, &got, &text)!!;
		assert(count == 3);
		assert(got[0].value == "ACME" && got[2].id == 2 && got[2].value == "1.0");
	};
}

// The blocking client speaks MBAP over a byte stream: an RTU configuration is refused at init, not at every call.
fn void test_blocking_client_refuses_rtu_framing() @test
{
	String[1] replies = { "" };
	Script s = { .replies = &replies };
	BlockingClient bc;
	ClientConfig k = client::default_config();
	k.framing = RTU;
	assert(@catch(bc.init((Transport)&s, k, mem)) == modbus::BAD_VALUE);
}

// ---- a stalled or idle client must not hold the server up ----

long srv_now = 0;

fn Clock srv_clock()
{
	return (Clock)srv_now;
}

// Moves the test clock of the server forward.
fn void advance(long seconds)
{
	srv_now += seconds * 1000000000;
}

fn void Net.use_test_clock(&self)
{
	srv_now = 1000000000;
	self.server.clock = &srv_clock;
}

fn void test_slow_reader_does_not_stall_the_server() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		n.use_test_clock();
		assert(n.server.write_timeout == time::sec(5) && n.server.idle_timeout == time::sec(60), "defaults");
		TcpTransport bad;
		n.connect(&bad);
		defer (void)bad.close();
		// a client that asks for 125 registers over and over and never reads an answer
		char[] burst = mem::temp_array(char, 12 * 100);
		for (usz i = 0; i < 100; i++)
		{
			usz len = frame::mbap_encode((ushort)(i + 1), 1, support::hx("03 00 00 00 7D"), burst[i * 12..])!!;
			assert(len == 12);
		}
		int sent = 0;
		while (n.server.blocked_connections() == 0)
		{
			assert(sent < 2000, "the server never ran out of room to answer: raise the limit");
			bad.write(burst, time::sec(2))!!;
			n.step(2);
			sent++;
		}
		// the server did not wait for the slow reader: a second client is served in the very next rounds
		TcpTransport good;
		n.connect(&good);
		defer (void)good.close();
		good.write(support::hx("00 01 00 00 00 06 01 06 00 02 00 09"), time::sec(1))!!;
		n.step(4);
		support::assert_bytes(read_all(&good, 12), "00 01 00 00 00 06 01 06 00 02 00 09");
		assert(n.map.holding[2] == 9);
		assert(n.server.connection_count() == 2, "the slow reader is still connected until its deadline");
		// once its output has stayed blocked past the write deadline the connection is dropped
		advance(10);
		n.step(2);
		assert(n.server.connection_count() == 1);
		assert(n.server.blocked_connections() == 0);
		good.write(support::hx("00 02 00 00 00 06 01 03 00 02 00 01"), time::sec(1))!!;
		n.step(3);
		support::assert_bytes(read_all(&good, 11), "00 02 00 00 00 05 01 03 02 00 09");
	};
}

fn void test_idle_connections_are_dropped() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		n.use_test_clock();
		n.server.idle_timeout = time::sec(30);
		TcpTransport[8] idle;
		for (usz i = 0; i < 8; i++) n.connect(&idle[i]);
		n.step(10);
		assert(n.server.connection_count() == 8);
		// the server is full: a ninth client is turned away
		TcpTransport late;
		n.connect(&late);
		n.step(3);
		char[8] buf;
		assert(@catch(late.read(&buf, time::sec(1))) == modbus::CLOSED);
		// a connection that talks stays; the silent ones go after the idle timeout
		advance(20);
		idle[3].write(support::hx("00 01 00 00 00 06 01 03 00 00 00 01"), time::sec(1))!!;
		n.step(3);
		assert(read_all(&idle[3], 11).len == 11);
		assert(n.server.connection_count() == 8);
		advance(20);
		n.step(2);
		assert(n.server.connection_count() == 1, "only the client that was active 20 s ago is left");
		// and the server takes new clients again
		TcpTransport again;
		n.connect(&again);
		again.write(support::hx("00 05 00 00 00 06 01 03 00 00 00 01"), time::sec(1))!!;
		n.step(4);
		assert(read_all(&again, 11).len == 11);
		for (usz i = 0; i < 8; i++) (void)idle[i].close();
		(void)late.close();
		(void)again.close();
	};
}

fn void test_idle_timeout_can_be_switched_off() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		n.use_test_clock();
		n.server.idle_timeout = time::DURATION_ZERO;
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		n.step(3);
		advance(100000);
		n.step(3);
		assert(n.server.connection_count() == 1);
	};
}

// ---- clients that trickle must not keep a slot either ----

fn void test_trickling_request_is_dropped() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		n.use_test_clock();
		assert(n.server.read_timeout == time::sec(10), "default read deadline");
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		char[] req = support::hx("00 01 00 00 00 06 01 03 00 00 00 01");
		// one byte now, another every 6 s: the request never completes and the idle timer never fires
		t.write(req[0:1], time::sec(1))!!;
		n.step(3);
		for (usz i = 1; i < 6; i++)
		{
			advance(6);
			t.write(req[i:1], time::sec(1))!!;
			n.step(2);
			if (n.server.connection_count() == 0) break;
		}
		assert(n.server.connection_count() == 0, "a request that takes longer than the read deadline is dropped");
	};
}

fn void test_slow_but_complete_request_is_served() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		n.use_test_clock();
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		char[] req = support::hx("00 01 00 00 00 06 01 03 00 00 00 01");
		t.write(req[:5], time::sec(1))!!;
		n.step(3);
		advance(5);
		t.write(req[5..], time::sec(1))!!;
		n.step(3);
		support::assert_bytes(read_all(&t, 11), "00 01 00 00 00 05 01 03 02 00 00");
		// the next request starts a new timer: another slow one is fine
		t.write(req[:5], time::sec(1))!!;
		n.step(3);
		advance(8);
		t.write(req[5..], time::sec(1))!!;
		n.step(3);
		assert(read_all(&t, 11).len == 11);
		assert(n.server.connection_count() == 1);
	};
}

// A reader that takes a few bytes now and then: its output has been pending for too long, whatever it takes meanwhile.
fn void test_slow_drainer_is_dropped() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		n.use_test_clock();
		TcpTransport bad;
		n.connect(&bad);
		defer (void)bad.close();
		char[] burst = mem::temp_array(char, 12 * 100);
		for (usz i = 0; i < 100; i++)
		{
			usz len = frame::mbap_encode((ushort)(i + 1), 1, support::hx("03 00 00 00 7D"), burst[i * 12..])!!;
			assert(len == 12);
		}
		int sent = 0;
		while (n.server.blocked_connections() == 0)
		{
			assert(sent < 2000, "the server never ran out of room to answer");
			bad.write(burst, time::sec(2))!!;
			n.step(2);
			sent++;
		}
		// the client reads a little every 2 s: it makes progress, but its output stays blocked
		char[2000] sink;
		for (int i = 0; i < 4; i++)
		{
			advance(2);
			(void)bad.read(&sink, time::ms(20));
			n.step(2);
		}
		assert(n.server.connection_count() == 0, "dropped although it keeps draining a little");
	};
}

// Pipelined requests must be answered in one round, not one output buffer per poll timeout: the server loops
// while flushing frees room for the requests it already holds.
fn void test_pipelined_requests_are_answered_in_one_round() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		n.use_test_clock();                              // time never advances
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		n.step(2);                                       // accepted
		char[] batch = mem::temp_array(char, 12 * 20);
		for (usz i = 0; i < 20; i++)
		{
			usz len = frame::mbap_encode((ushort)(i + 1), 1, support::hx("03 00 00 00 7D"), batch[i * 12..])!!;
			assert(len == 12);
		}
		t.write(batch, time::sec(1))!!;
		n.step(1);                                       // a single round
		char[] all = read_all(&t, 20 * 259);
		for (usz i = 0; i < 20; i++)
		{
			char[] f = all[i * 259:259];
			assert(f[1] == (char)(i + 1) && f[0] == 0, "answer %d in order", i);
			assert(f[7] == 3 && f[8] == 250);
		}
	};
}

// After a failed accept (out of file descriptors) the listener is left alone for a moment: it stays readable and
// would make serve() spin. Here the back-off is set by hand, as the failure cannot be provoked portably.
fn void test_listener_is_skipped_during_the_accept_back_off() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		n.use_test_clock();
		n.server.accept_retry_at = (Clock)(srv_now + 100000000);     // 100 ms from now
		TcpTransport t;
		n.connect(&t);
		defer (void)t.close();
		n.step(3);
		assert(n.server.connection_count() == 0, "not accepted while backing off");
		advance(1);
		n.step(3);
		assert(n.server.connection_count() == 1, "accepted once the back-off is over");
		t.write(support::hx("00 01 00 00 00 06 01 03 00 00 00 01"), time::sec(1))!!;
		n.step(3);
		assert(read_all(&t, 11).len == 11);
	};
}

// Zero switches a deadline off, as for idle_timeout: a blocked connection is then kept.
fn void test_zero_write_timeout_switches_the_deadline_off() @test
{
	@pool()
	{
		Net n;
		n.setup();
		defer n.teardown();
		n.use_test_clock();
		n.server.write_timeout = time::DURATION_ZERO;
		n.server.idle_timeout = time::DURATION_ZERO;
		TcpTransport bad;
		n.connect(&bad);
		defer (void)bad.close();
		char[] burst = mem::temp_array(char, 12 * 100);
		for (usz i = 0; i < 100; i++)
		{
			usz len = frame::mbap_encode((ushort)(i + 1), 1, support::hx("03 00 00 00 7D"), burst[i * 12..])!!;
			assert(len == 12);
		}
		int sent = 0;
		while (n.server.blocked_connections() == 0)
		{
			assert(sent < 2000, "the server never ran out of room to answer");
			bad.write(burst, time::sec(2))!!;
			n.step(2);
			sent++;
		}
		advance(1000000);
		n.step(3);
		assert(n.server.connection_count() == 1, "no write deadline: the blocked connection stays");
	};
}
