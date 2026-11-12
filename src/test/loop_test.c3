module modbus::loop_test;

import std::core::mem;
import std::time;
import modbus;
import modbus::client;
import modbus::pdu;
import modbus::server;
import modbus::support;

// A client and a server connection joined in memory; the byte streams between them are cut into random chunks.

struct Rng
{
	uint state;
}

fn uint Rng.next(&self)
{
	self.state = self.state * 1664525 + 1013904223;
	return self.state >> 8;
}

fn uint Rng.below(&self, uint n)
{
	return self.next() % n;
}

fn Clock at(long ms)
{
	return (Clock)(ms * 1000000);
}

struct Expect
{
	char fc;
	char[250] data;
	usz len;
	ushort addr;
	ushort qty;
	ushort value;
	ushort and_mask;
	ushort or_mask;
	bool seen;
}

struct Loop
{
	Client client;
	ServerConn server;
	ServerConfig cfg;
	RegisterMap map;
	Rng rng;
	// the shadow model: what the map must hold if every request was applied in order
	bool[200] coils;
	ushort[200] holding;
	Expect[256] expect;
	usz seen;
	usz sent;
}

fn void Loop.setup(&self, usz pending, uint seed)
{
	self.rng.state = seed;
	self.map.init(mem, 200, 10, 200, 10)!!;
	self.cfg.accept_any_unit = true;
	self.cfg.allow_diagnostics = true;
	self.cfg.server_id = support::hx("01 FF 41");
	self.cfg.conformity_level = 1;
	pdu::DeviceObject[] objs = mem::new_array(pdu::DeviceObject, 3);
	objs[0] = { 0, "ACME" };
	objs[1] = { 1, "X1" };
	objs[2] = { 2, "1.0" };
	self.cfg.device_objects = objs;
	self.server.init(&self.cfg, (DataModel)&self.map, mem)!!;
	ClientConfig k = client::default_config();
	k.max_pending = pending;
	k.allow_write = true;
	k.timeout = time::sec(60);
	self.client.init(k, mem)!!;
}

fn void Loop.teardown(&self)
{
	mem::free(self.cfg.device_objects.ptr);
	self.client.free();
	self.server.free();
	self.map.free();
}

fn void Loop.check_event(&self, Event* ev)
{
	assert(ev.kind == EventKind.RESPONSE, "event %d kind %d error %s", ev.cookie, (int)ev.kind, ev.error);
	Expect* e = &self.expect[ev.cookie];
	assert(!e.seen, "answer %d twice", ev.cookie);
	e.seen = true;
	self.seen++;
	assert(ev.response.fc == e.fc, "fc of %d", ev.cookie);
	switch ((Fc)e.fc)
	{
		case READ_COILS:
		case READ_HOLDING_REGISTERS:
		case READ_WRITE_MULTIPLE_REGISTERS:
		case DIAGNOSTICS:
		case REPORT_SERVER_ID:
			assert(ev.response.data.len == e.len, "data length of %d (fc %02x): got %d, want %d", ev.cookie, e.fc, ev.response.data.len, e.len);
			for (usz i = 0; i < e.len; i++) assert(ev.response.data[i] == e.data[i], "byte %d of answer %d (fc %02x)", i, ev.cookie, e.fc);
		case WRITE_SINGLE_COIL:
		case WRITE_SINGLE_REGISTER:
			assert(ev.response.addr == e.addr && ev.response.value == e.value, "echo of %d", ev.cookie);
		case WRITE_MULTIPLE_COILS:
		case WRITE_MULTIPLE_REGISTERS:
			assert(ev.response.addr == e.addr && ev.response.qty == e.qty, "echo of %d", ev.cookie);
		case MASK_WRITE_REGISTER:
			assert(ev.response.addr == e.addr && ev.response.and_mask == e.and_mask && ev.response.or_mask == e.or_mask, "echo of %d", ev.cookie);
		case ENCAPSULATED_INTERFACE:
			assert(ev.response.object_count == 3 && !ev.response.more_follows, "device id of %d", ev.cookie);
		default:
			unreachable("unexpected function");
	}
}

// Moves bytes both ways in random chunks until nothing is in flight, checking every answer.
fn void Loop.shuttle(&self, long now)
{
	int guard = 0;
	while (self.client.pending_count() > 0 || self.client.output().len > 0 || self.server.output().len > 0)
	{
		guard++;
		assert(guard < 200000, "the exchange does not finish");
		char[] co = self.client.output();
		if (co.len > 0)
		{
			usz k = (usz)(1 + self.rng.below(40));
			if (k > co.len) k = co.len;
			usz taken = self.server.feed(co[:k])!!;
			self.client.consume_output(taken);
		}
		char[] so = self.server.output();
		if (so.len > 0)
		{
			usz k = (usz)(1 + self.rng.below(40));
			if (k > so.len) k = so.len;
			usz taken = self.client.feed(so[:k])!!;
			self.server.consume_output(taken);
		}
		self.server.pump()!!;
		Event ev;
		while (self.client.poll(at(now), &ev)) self.check_event(&ev);
	}
}

fn void Loop.queue(&self, Request* r, Expect e)
{
	e.fc = r.fc;
	usz index = self.sent;
	self.expect[index] = e;
	self.client.send(r, at(0), index)!!;
	self.sent++;
}

fn void pack_bits(bool[] bits, usz start, usz qty, char[] out)
{
	for (usz i = 0; i < (qty + 7) / 8; i++) out[i] = 0;
	for (usz i = 0; i < qty; i++)
	{
		if (bits[start + i]) out[i / 8] |= (char)(1 << (i % 8));
	}
}

// One random request; the shadow model is updated in send order, which is the order the server executes.
fn void Loop.random_request(&self)
{
	char[300] scratch;
	Expect e;
	Rng* rng = &self.rng;
	switch (rng.below(11))
	{
		case 0:
			ushort qty = (ushort)(1 + rng.below(60));
			ushort addr = (ushort)rng.below(200 - qty + 1);
			Request r = pdu::read_request(Fc.READ_COILS, addr, qty);
			e.len = (usz)((qty + 7) / 8);
			pack_bits(&self.coils, addr, qty, &e.data);
			self.queue(&r, e);
		case 1:
			ushort qty = (ushort)(1 + rng.below(30));
			ushort addr = (ushort)rng.below(200 - qty + 1);
			Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, addr, qty);
			e.len = (usz)qty * 2;
			for (usz i = 0; i < qty; i++)
			{
				e.data[i * 2] = (char)(self.holding[addr + i] >> 8);
				e.data[i * 2 + 1] = (char)(self.holding[addr + i] & 0xFF);
			}
			self.queue(&r, e);
		case 2:
			ushort addr = (ushort)rng.below(200);
			bool on = rng.below(2) == 0;
			Request r = pdu::write_single_coil(addr, on);
			self.coils[addr] = on;
			e.addr = addr;
			e.value = on ? 0xFF00 : 0;
			self.queue(&r, e);
		case 3:
			ushort addr = (ushort)rng.below(200);
			ushort v = (ushort)rng.below(0x10000);
			Request r = pdu::write_single_register(addr, v);
			self.holding[addr] = v;
			e.addr = addr;
			e.value = v;
			self.queue(&r, e);
		case 4:
			usz n = (usz)(1 + rng.below(50));
			ushort addr = (ushort)rng.below((uint)(200 - n + 1));
			bool[50] bits;
			for (usz i = 0; i < n; i++)
			{
				bits[i] = rng.below(2) == 0;
				self.coils[addr + i] = bits[i];
			}
			Request r = pdu::write_multiple_coils(addr, bits[:n], &scratch)!!;
			e.addr = addr;
			e.qty = (ushort)n;
			self.queue(&r, e);
		case 5:
			usz n = (usz)(1 + rng.below(40));
			ushort addr = (ushort)rng.below((uint)(200 - n + 1));
			ushort[40] words;
			for (usz i = 0; i < n; i++)
			{
				words[i] = (ushort)rng.below(0x10000);
				self.holding[addr + i] = words[i];
			}
			Request r = pdu::write_multiple_registers(addr, words[:n], &scratch)!!;
			e.addr = addr;
			e.qty = (ushort)n;
			self.queue(&r, e);
		case 6:
			ushort addr = (ushort)rng.below(200);
			ushort and_mask = (ushort)rng.below(0x10000);
			ushort or_mask = (ushort)rng.below(0x10000);
			self.holding[addr] = (self.holding[addr] & and_mask) | (or_mask & ~and_mask);
			Request r = pdu::mask_write_register(addr, and_mask, or_mask);
			e.addr = addr;
			e.and_mask = and_mask;
			e.or_mask = or_mask;
			self.queue(&r, e);
		case 7:
			usz wn = (usz)(1 + rng.below(20));
			ushort rq = (ushort)(1 + rng.below(20));
			ushort waddr = (ushort)rng.below((uint)(200 - wn + 1));
			ushort raddr = (ushort)rng.below(200 - rq + 1);
			ushort[20] words;
			for (usz i = 0; i < wn; i++)
			{
				words[i] = (ushort)rng.below(0x10000);
				self.holding[waddr + i] = words[i];          // the write happens before the read
			}
			e.len = (usz)rq * 2;
			for (usz i = 0; i < rq; i++)
			{
				e.data[i * 2] = (char)(self.holding[raddr + i] >> 8);
				e.data[i * 2 + 1] = (char)(self.holding[raddr + i] & 0xFF);
			}
			Request r = pdu::read_write_registers(raddr, rq, waddr, words[:wn], &scratch)!!;
			self.queue(&r, e);
		case 8:
			scratch[0] = (char)rng.below(256);
			scratch[1] = (char)rng.below(256);
			Request r = { .fc = (char)Fc.DIAGNOSTICS, .sub = 0, .data = scratch[:2] };
			e.len = 2;
			e.data[0] = scratch[0];
			e.data[1] = scratch[1];
			self.queue(&r, e);
		case 9:
			Request r = { .fc = (char)Fc.REPORT_SERVER_ID };
			e.len = 3;
			e.data[0] = 0x01;
			e.data[1] = 0xFF;
			e.data[2] = 0x41;
			self.queue(&r, e);
		default:
			Request r = pdu::read_device_id(1, 0);
			self.queue(&r, e);
	}
}

fn void check_model(Loop* l)
{
	for (usz i = 0; i < 200; i++)
	{
		assert(l.map.coils[i] == l.coils[i], "coil %d", i);
		assert(l.map.holding[i] == l.holding[i], "register %d", i);
	}
}

fn void run_loop(usz pending, uint seed)
{
	Loop* l = mem::new(Loop);        // too big for the stack
	l.setup(pending, seed);
	defer
	{
		l.teardown();
		mem::free(l);
	}
	long now = 0;
	while (l.sent < 200)
	{
		usz batch = (usz)(1 + l.rng.below((uint)pending));
		for (usz i = 0; i < batch && l.sent < 200; i++) l.random_request();
		l.shuttle(now++);
	}
	assert(l.seen == 200, "answers seen: %d", l.seen);
	check_model(l);
}

fn void test_mixed_requests_one_at_a_time() @test
{
	run_loop(1, 1234);
}

fn void test_mixed_requests_pipelined() @test
{
	run_loop(4, 99);
}

fn void test_mixed_requests_deeply_pipelined() @test
{
	run_loop(16, 2026);
}

// ---- device identification across several answers, driven through the client ----

fn void test_device_id_loop() @test
{
	@pool()
	{
		char[100] text;
		for (usz i = 0; i < 100; i++) text[i] = (char)('a' + i % 26);
		pdu::DeviceObject[] objs = mem::temp_array(pdu::DeviceObject, 3);
		for (usz i = 0; i < 3; i++) objs[i] = { (char)i, (String)text[:100] };
		RegisterMap map;
		map.init(mem, 1, 1, 1, 1)!!;
		defer map.free();
		ServerConfig cfg = { .accept_any_unit = true, .device_objects = objs, .conformity_level = 1 };
		ServerConn s;
		s.init(&cfg, (DataModel)&map, mem)!!;
		defer s.free();
		Client c;
		c.init(client::default_config(), mem)!!;
		defer c.free();

		char next = 0;
		usz rounds = 0;
		usz total = 0;
		bool more = true;
		while (more)
		{
			rounds++;
			assert(rounds <= 16, "round cap");
			Request r = pdu::read_device_id(1, next);
			c.send(&r, at(0))!!;
			s.feed(c.output())!!;
			c.consume_output(c.output().len);
			c.feed(s.output())!!;
			s.consume_output(s.output().len);
			Event ev;
			assert(c.poll(at(1), &ev) && ev.kind == EventKind.RESPONSE);
			pdu::ObjectIter it = pdu::objects(&ev.response);
			pdu::DeviceObject o;
			while (it.next(&o)!!)
			{
				assert(o.id == (char)total && o.value.len == 100);
				total++;
			}
			more = ev.response.more_follows;
			if (more)
			{
				// the progress rule of the blocking helper: the next id must move forward
				assert(ev.response.next_object_id > next, "no progress");
				next = ev.response.next_object_id;
			}
		}
		assert(total == 3 && rounds == 2);
	};
}
