module modbus::fuzz_test;

import std::core::mem;
import std::time;
import modbus;
import modbus::client;
import modbus::pdu;

struct Rng
{
	uint state;
}

fn uint Rng.next(&self)
{
	self.state = self.state * 1664525 + 1013904223;
	return self.state >> 8;
}

fn Clock at(long ms)
{
	return (Clock)(ms * 1000000);
}

// Drains all events; the client must stay consistent whatever arrived.
fn usz drain(Client* c, Clock now)
{
	usz n = 0;
	Event ev;
	while (c.poll(now, &ev))
	{
		n++;
		assert(n < 100000, "poll does not terminate");
		if (ev.kind == EventKind.RESPONSE)
		{
			// touching the borrowed data must stay inside the frame
			usz regs = ev.response.reg_count();
			for (usz i = 0; i < regs; i++) ev.response.reg(i);
			for (usz i = 0; i < ev.response.qty && i < 300; i++) ev.response.coil(i);
		}
	}
	return n;
}

fn void test_random_bytes_into_tcp_client() @test
{
	Rng rng = { .state = 7 };
	ClientConfig k = client::default_config();
	k.max_pending = 4;
	k.timeout = time::ms(50);
	Client c;
	c.init(k, mem)!!;
	defer c.free();
	Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 3);
	char[40] chunk;
	usz total = 0;
	long now = 0;
	while (total < 10000)
	{
		usz n = (usz)(1 + rng.next() % 40);
		for (usz i = 0; i < n; i++) chunk[i] = (char)rng.next();
		now += 3;
		if (c.broken)
		{
			drain(&c, at(now));
			c.free();
			c.init(k, mem)!!;
		}
		if (rng.next() % 3 == 0) (void)c.send(&r, at(now), total);
		c.consume_output(c.output().len);
		usz taken = c.feed(chunk[:n])!!;
		total += taken;
		drain(&c, at(now));
	}
	assert(total >= 10000);
}

// Frames with a valid MBAP header and a random PDU reach the response decoder.
fn void test_random_pdus_in_valid_frames() @test
{
	Rng rng = { .state = 99 };
	ClientConfig k = client::default_config();
	k.max_pending = 1;
	k.timeout = time::ms(1000);
	Client c;
	c.init(k, mem)!!;
	defer c.free();
	char[3] fcs = { 3, 1, 5 };
	for (int round = 0; round < 3000; round++)
	{
		Request r = pdu::read_request(round % 2 == 0 ? Fc.READ_HOLDING_REGISTERS : Fc.READ_COILS, 0, (ushort)(1 + rng.next() % 20));
		ushort tid = c.send(&r, at(round), (ulong)round)!!;
		c.consume_output(c.output().len);
		usz plen = (usz)(1 + rng.next() % 30);
		char[64] frame;
		frame[0] = (char)(tid >> 8);
		frame[1] = (char)(tid & 0xFF);
		frame[2] = 0;
		frame[3] = 0;
		frame[4] = 0;
		frame[5] = (char)(plen + 1);
		frame[6] = 1;
		for (usz i = 0; i < plen; i++) frame[7 + i] = (char)rng.next();
		if (rng.next() % 2 == 0) frame[7] = r.fc;                   // often the right function code
		if (rng.next() % 4 == 0 && plen > 1) frame[8] = (char)(rng.next() % 12);
		assert(c.feed(frame[:7 + plen])!! == 7 + plen);
		Event ev;
		assert(c.poll(at(round), &ev));
		assert(ev.kind != EventKind.TIMEOUT);
		assert(!ev.fatal);
		assert(!c.poll(at(round), &ev));
		assert(c.pending_count() == 0);
	}
}

fn void test_random_frames_into_rtu_client() @test
{
	Rng rng = { .state = 5 };
	ClientConfig k = client::default_config();
	k.framing = RTU;
	k.timeout = time::ms(100);
	Client c;
	c.init(k, mem)!!;
	defer c.free();
	Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 3);
	char[300] frame;
	for (int round = 0; round < 2000; round++)
	{
		(void)c.send(&r, at(round), (ulong)round);
		c.consume_output(c.output().len);
		usz n = (usz)(rng.next() % 300);
		for (usz i = 0; i < n; i++) frame[i] = (char)rng.next();
		(void)c.feed_frame(frame[:n]);
		drain(&c, at((long)round + 200));
	}
}
