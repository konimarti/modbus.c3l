module modbus::client_test;

import std::core::mem;
import std::time;
import modbus;
import modbus::client;
import modbus::pdu;
import modbus::support;

// A point on the test clock, in milliseconds (the core never reads a clock; tests build Clock values by hand).
fn Clock at(long ms)
{
	return (Clock)(ms * 1000000);
}

fn ClientConfig cfg(usz pending = 4)
{
	ClientConfig c = client::default_config();
	c.max_pending = pending;
	c.timeout = time::ms(1000);
	c.unit = 1;
	return c;
}

fn Request read3()
{
	return pdu::read_request(Fc.READ_HOLDING_REGISTERS, 107, 3);
}

// Feeds all of `data`, polling when the framer is full; returns every event.
fn void feed_all(Client* c, char[] data)
{
	usz taken = c.feed(data)!!;
	assert(taken == data.len);
}

// ---- send and the first response (TV: read 3 holding registers, TV-M2 style) ----

fn void test_send_read_and_response() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		ushort tid = c.send(&r, at(100), 77)!!;
		assert(tid == 1);
		support::assert_bytes(c.output(), "00 01 00 00 00 06 01 03 00 6B 00 03");
		assert(c.pending_count() == 1);
		feed_all(&c, support::hx("00 01 00 00 00 09 01 03 06 02 2B 00 00 00 64"));
		Event ev;
		assert(c.poll(at(101), &ev));
		assert(ev.kind == EventKind.RESPONSE && ev.cookie == 77 && ev.tid == 1 && ev.unit == 1);
		assert(!ev.fatal && !ev.response.is_exception);
		assert(ev.response.reg(0) == 555 && ev.response.reg(1) == 0 && ev.response.reg(2) == 100);
		assert(ev.request.fc == 3 && ev.request.addr == 107 && ev.request.qty == 3);
		assert(ev.request.data.len == 0);
		assert(c.pending_count() == 0);
		assert(!c.poll(at(102), &ev));
	};
}

fn void test_unit_default_and_override() @test
{
	@pool()
	{
		Client c;
		ClientConfig k = cfg();
		k.unit = 0x11;
		c.init(k, mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0))!!;
		support::assert_bytes(c.output(), "00 01 00 00 00 06 11 03 00 6B 00 03");     // TV-M1
		c.consume_output(c.output().len);
		c.send(&r, at(0), 0, 0)!!;                                                       // unit 0 is a real id
		support::assert_bytes(c.output(), "00 02 00 00 00 06 00 03 00 6B 00 03");
		c.consume_output(c.output().len);
		c.send(&r, at(0), 0, 255)!!;
		support::assert_bytes(c.output(), "00 03 00 00 00 06 FF 03 00 6B 00 03");
		assert(@catch(c.send(&r, at(0), 0, 256)) == modbus::BAD_VALUE);
		assert(@catch(c.send(&r, at(0), 0, -2)) == modbus::BAD_VALUE);
	};
}

fn void test_consume_output_partial() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0))!!;
		c.consume_output(5);
		support::assert_bytes(c.output(), "06 01 03 00 6B 00 03");
		c.consume_output(100);
		assert(c.output().len == 0);
	};
}

// ---- pipelining (S1) ----

fn void test_pipelined_answers_match_by_tid() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request a = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		Request b = pdu::read_request(Fc.READ_INPUT_REGISTERS, 8, 1);
		c.send(&a, at(0), 10)!!;
		c.send(&b, at(0), 20)!!;
		// the answer to tid 2 comes first
		feed_all(&c, support::hx("00 02 00 00 00 05 01 04 02 00 0A"));
		feed_all(&c, support::hx("00 01 00 00 00 05 01 03 02 00 07"));
		Event ev;
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.RESPONSE && ev.cookie == 20 && ev.response.fc == 4 && ev.response.reg(0) == 10);
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.RESPONSE && ev.cookie == 10 && ev.response.fc == 3 && ev.response.reg(0) == 7);
		assert(!c.poll(at(1), &ev));
	};
}

fn void test_response_split_into_single_bytes() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0), 5)!!;
		char[] msg = support::hx("00 01 00 00 00 09 01 03 06 02 2B 00 00 00 64");
		Event ev;
		foreach (i, b : msg)
		{
			assert(c.feed(msg[i:1])!! == 1);
			bool got = c.poll(at(1), &ev);
			assert(got == (i == msg.len - 1), "event only after the last byte (%d)", i);
		}
		assert(ev.kind == EventKind.RESPONSE && ev.response.reg(2) == 100);
	};
}

// The data of the first response must still be intact after the second one was decoded:
// both frames arrived in one feed, the borrowed bytes stay valid until the next poll or feed.
fn void test_two_responses_in_one_feed() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request a = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		Request b = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 5, 2);
		c.send(&a, at(0), 1)!!;
		c.send(&b, at(0), 2)!!;
		feed_all(&c, support::hx("00 01 00 00 00 05 01 03 02 11 11 00 02 00 00 00 07 01 03 04 22 22 33 33"));
		Event e1;
		Event e2;
		assert(c.poll(at(1), &e1));
		assert(e1.cookie == 1 && e1.response.reg(0) == 0x1111);
		assert(c.poll(at(1), &e2));
		assert(e2.cookie == 2 && e2.response.reg(0) == 0x2222 && e2.response.reg(1) == 0x3333);
		assert(!c.poll(at(1), &e2));
	};
}

fn void test_data_valid_until_next_poll() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request a = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		Request b = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 5, 1);
		c.send(&a, at(0), 1)!!;
		c.send(&b, at(0), 2)!!;
		feed_all(&c, support::hx("00 01 00 00 00 05 01 03 02 AA AA 00 02 00 00 00 05 01 03 02 BB BB"));
		Event ev;
		assert(c.poll(at(1), &ev));
		// nothing was decoded yet for frame 2: frame 1's bytes are untouched right after the first poll
		assert(ev.response.reg(0) == 0xAAAA);
		assert(c.pending_count() == 1);
	};
}

// ---- exceptions ----

fn void test_exception_event() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0), 3)!!;
		feed_all(&c, support::hx("00 01 00 00 00 03 01 83 02"));                    // TV-M4 style
		Event ev;
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.EXCEPTION && ev.response.is_exception && ev.response.exception == ExceptionCode.ILLEGAL_DATA_ADDRESS);
		assert(ev.cookie == 3 && !ev.fatal);
		assert(c.pending_count() == 0);
	};
}

fn void test_exception_raw_codes_through_client() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		String[] frames = { "00 01 00 00 00 03 01 83 00", "00 02 00 00 00 03 01 83 07", "00 03 00 00 00 03 01 83 FF" };
		char[3] codes = { 0x00, 0x07, 0xFF };
		foreach (i, f : frames)
		{
			c.send(&r, at(0))!!;
			feed_all(&c, support::hx(f));
			Event ev;
			assert(c.poll(at(1), &ev));
			assert(ev.kind == EventKind.EXCEPTION && ev.response.is_exception);
			assert((char)ev.response.exception == codes[i]);
		}
	};
}

fn void test_exception_for_other_function_is_error() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0))!!;
		feed_all(&c, support::hx("00 01 00 00 00 03 01 81 02"));
		Event ev;
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.PROTOCOL_ERROR && ev.error == modbus::MISMATCH && !ev.fatal);
		assert(c.pending_count() == 0);
	};
}

// ---- timeouts (S2) ----

fn void test_timeout_and_next_deadline() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Clock dl;
		assert(!c.next_deadline(&dl));
		Request r = read3();
		c.send(&r, at(100), 9)!!;
		assert(c.next_deadline(&dl));
		assert(dl == at(1100));
		Event ev;
		assert(!c.poll(at(1099), &ev));
		assert(c.pending_count() == 1);
		assert(c.poll(at(1100), &ev));
		assert(ev.kind == EventKind.TIMEOUT && ev.error == modbus::TIMEOUT && ev.cookie == 9 && ev.tid == 1 && !ev.fatal);
		assert(c.pending_count() == 0);
		assert(!c.next_deadline(&dl));
		assert(!c.poll(at(5000), &ev));
	};
}

fn void test_earliest_deadline_first() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(300), 1)!!;
		c.send(&r, at(100), 2)!!;
		c.send(&r, at(200), 3)!!;
		Clock dl;
		assert(c.next_deadline(&dl) && dl == at(1100));
		Event ev;
		assert(c.poll(at(5000), &ev) && ev.cookie == 2);
		assert(c.poll(at(5000), &ev) && ev.cookie == 3);
		assert(c.poll(at(5000), &ev) && ev.cookie == 1);
		assert(!c.poll(at(5000), &ev));
	};
}

fn void test_late_response_is_dropped() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0), 4)!!;
		Event ev;
		assert(c.poll(at(2000), &ev) && ev.kind == EventKind.TIMEOUT);
		feed_all(&c, support::hx("00 01 00 00 00 09 01 03 06 02 2B 00 00 00 64"));
		assert(c.poll(at(2001), &ev));
		assert(ev.kind == EventKind.PROTOCOL_ERROR && ev.error == modbus::UNKNOWN_TRANSACTION && !ev.fatal);   // X11
		assert(ev.tid == 1);
		// the stream is still usable
		c.send(&r, at(2002), 5)!!;
		feed_all(&c, support::hx("00 02 00 00 00 09 01 03 06 00 01 00 02 00 03"));
		assert(c.poll(at(2003), &ev));
		assert(ev.kind == EventKind.RESPONSE && ev.cookie == 5);
	};
}

fn void test_pending_frame_is_decoded_before_timeout() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0), 6)!!;
		feed_all(&c, support::hx("00 01 00 00 00 09 01 03 06 00 01 00 02 00 03"));
		Event ev;
		// the answer is already buffered when the deadline passes: it wins
		assert(c.poll(at(5000), &ev));
		assert(ev.kind == EventKind.RESPONSE);
		assert(!c.poll(at(5000), &ev));
	};
}

// ---- unit id (X10) ----

fn void test_unit_mismatch() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0), 8)!!;
		feed_all(&c, support::hx("00 01 00 00 00 09 02 03 06 00 01 00 02 00 03"));
		Event ev;
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.PROTOCOL_ERROR && ev.error == modbus::MISMATCH && !ev.fatal);
		assert(ev.cookie == 8 && ev.unit == 2);
		assert(c.pending_count() == 0);
	};
}

fn void test_unit_check_off_accepts_zero_and_ff() @test
{
	@pool()
	{
		Client c;
		ClientConfig k = cfg();
		k.check_unit = false;
		c.init(k, mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0), 1)!!;
		feed_all(&c, support::hx("00 01 00 00 00 09 00 03 06 00 01 00 02 00 03"));
		Event ev;
		assert(c.poll(at(1), &ev) && ev.kind == EventKind.RESPONSE);
		c.send(&r, at(0), 2)!!;
		feed_all(&c, support::hx("00 02 00 00 00 09 FF 03 06 00 01 00 02 00 03"));
		assert(c.poll(at(1), &ev) && ev.kind == EventKind.RESPONSE && ev.cookie == 2);
	};
}

// ---- broken streams (S5) ----

fn void test_bad_protocol_id_breaks_stream() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0), 1)!!;
		c.send(&r, at(0), 2)!!;
		feed_all(&c, support::hx("00 01 00 01 00 09 01 03 06 00 01 00 02 00 03"));
		Event ev;
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.PROTOCOL_ERROR && ev.error == modbus::BAD_PROTOCOL_ID && ev.fatal);
		// both pending requests then fail with a fatal event each
		assert(c.poll(at(1), &ev) && ev.fatal && ev.error == modbus::BAD_PROTOCOL_ID && ev.cookie == 1);
		assert(c.poll(at(1), &ev) && ev.fatal && ev.cookie == 2);
		assert(!c.poll(at(1), &ev));
		assert(@catch(c.send(&r, at(2))) == modbus::CLOSED);
		assert(@catch(c.feed(support::hx("00"))) == modbus::CLOSED);
	};
}

fn void test_bad_length_breaks_stream() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0), 1)!!;
		feed_all(&c, support::hx("00 01 00 00 00 01 01"));
		Event ev;
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.PROTOCOL_ERROR && ev.error == modbus::BAD_LENGTH && ev.fatal);
		assert(c.poll(at(1), &ev) && ev.fatal && ev.cookie == 1);
		assert(!c.poll(at(1), &ev));
	};
}

fn void test_fail_all_on_transport_close() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0), 1)!!;
		c.send(&r, at(0), 2)!!;
		c.fail_all(modbus::CLOSED);
		Event ev;
		assert(c.poll(at(1), &ev) && ev.kind == EventKind.PROTOCOL_ERROR && ev.error == modbus::CLOSED && ev.fatal);
		assert(c.poll(at(1), &ev) && ev.error == modbus::CLOSED && ev.fatal);
		assert(!c.poll(at(1), &ev));
		assert(c.pending_count() == 0);
		assert(@catch(c.send(&r, at(2))) == modbus::CLOSED);
	};
}

fn void test_response_pdu_error_is_not_fatal() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0), 1)!!;
		// X9: MBAP length 5 carries a 4-byte PDU `03 00 6B 00`: the PDU does not decode as a read response
		feed_all(&c, support::hx("00 01 00 00 00 05 01 03 00 6B 00"));
		Event ev;
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.PROTOCOL_ERROR && ev.error == modbus::BAD_BYTE_COUNT && !ev.fatal);
		assert(c.pending_count() == 0);
		// a response of the wrong size for its request
		c.send(&r, at(0), 2)!!;
		feed_all(&c, support::hx("00 02 00 00 00 07 01 03 04 00 01 00 02"));
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.PROTOCOL_ERROR && ev.error == modbus::BAD_BYTE_COUNT);
	};
}

// ---- limits of send ----

fn void test_too_many_pending_and_output_full() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(2), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0))!!;
		c.send(&r, at(0))!!;
		assert(@catch(c.send(&r, at(0))) == modbus::TOO_MANY_PENDING);
		assert(c.pending_count() == 2);

		// output room for 21 requests of 12 bytes (252 of 260 bytes), the 22nd does not fit
		Client d;
		ClientConfig k = cfg(30);
		k.output_size = 260;
		d.init(k, mem)!!;
		defer d.free();
		for (int i = 0; i < 21; i++) d.send(&r, at(0))!!;
		assert(@catch(d.send(&r, at(0))) == modbus::OUTPUT_FULL);
		assert(d.pending_count() == 21);
		d.consume_output(d.output().len);
		assert(d.send(&r, at(0))!! > 0);
	};
}

fn void test_init_checks() @test
{
	Client c;
	ClientConfig k = cfg();
	k.output_size = 259;
	assert(@catch(c.init(k, mem)) == modbus::BUFFER_TOO_SMALL);
	k.output_size = 260;
	c.init(k, mem)!!;
	c.free();
	k = cfg();
	k.max_pending = 0;
	assert(@catch(c.init(k, mem)) == modbus::BAD_VALUE);
}

fn void test_send_limit_checks_queue_nothing() @test
{
	@pool()
	{
		Client c;
		ClientConfig k = cfg();
		k.allow_write = true;
		c.init(k, mem)!!;
		defer c.free();
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 0);
		assert(@catch(c.send(&r, at(0))) == modbus::BAD_QUANTITY);
		r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 126);
		assert(@catch(c.send(&r, at(0))) == modbus::BAD_QUANTITY);
		r = pdu::read_request(Fc.READ_COILS, 0, 2001);
		assert(@catch(c.send(&r, at(0))) == modbus::BAD_QUANTITY);
		r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0xFFFF, 2);
		assert(@catch(c.send(&r, at(0))) == modbus::BAD_ADDRESS_RANGE);
		char[400] scratch;
		ushort[123] regs123;
		// the builders refuse the over-long writes, so build the request by hand
		Request w = { .fc = (char)Fc.WRITE_MULTIPLE_REGISTERS, .qty = 124, .data = scratch[:248] };
		assert(@catch(c.send(&w, at(0))) == modbus::BAD_QUANTITY);
		Request rw = { .fc = (char)Fc.READ_WRITE_MULTIPLE_REGISTERS, .qty = 1, .write_qty = 122, .data = scratch[:244] };
		assert(@catch(c.send(&rw, at(0))) == modbus::BAD_QUANTITY);
		Request coils = { .fc = (char)Fc.WRITE_MULTIPLE_COILS, .qty = 1969, .data = scratch[:247] };
		assert(@catch(c.send(&coils, at(0))) == modbus::BAD_QUANTITY);
		Request badbytes = { .fc = (char)Fc.WRITE_MULTIPLE_COILS, .qty = 8, .data = scratch[:2] };
		assert(@catch(c.send(&badbytes, at(0))) == modbus::BAD_BYTE_COUNT);
		Request unknown = { .fc = 0x41 };
		assert(@catch(c.send(&unknown, at(0))) == modbus::UNSUPPORTED_FUNCTION);
		assert(c.pending_count() == 0);
		assert(c.output().len == 0);
		// the largest legal write still goes through
		Request ok = pdu::write_multiple_registers(0, &regs123, &scratch)!!;
		assert(c.send(&ok, at(0))!! == 1);
		assert(c.output().len == 7 + 252);
	};
}

// ---- tid handling (S4) ----

fn void test_tid_wrap_skips_pending_id() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(2), mem)!!;
		defer c.free();
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		// tid 1 stays pending for the whole run (a very slow device)
		assert(c.send(&r, at(0), 999)!! == 1);
		c.consume_output(c.output().len);
		bool wrapped = false;
		bool saw_zero = false;
		ushort last = 1;
		for (int i = 0; i < 65536; i++)
		{
			ushort tid = c.send(&r, at(0), 1)!!;
			assert(tid != 1, "pending id 1 reused in round %d", i);
			if (tid == 0) saw_zero = true;
			if (tid < last) wrapped = true;
			last = tid;
			// answer it at once
			char[] ans = support::hx("00 00 00 00 00 05 01 03 02 00 00");
			ans[0] = (char)(tid >> 8);
			ans[1] = (char)(tid & 0xFF);
			c.consume_output(c.output().len);
			assert(c.feed(ans)!! == ans.len);
			Event ev;
			assert(c.poll(at(1), &ev));
			assert(ev.kind == EventKind.RESPONSE && ev.tid == tid);
		}
		assert(wrapped && saw_zero);
		assert(c.pending_count() == 1);
	};
}

fn void test_response_with_max_tid() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		c.next_tid = 0xFFFF;
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 10);
		assert(c.send(&r, at(0), 3)!! == 0xFFFF);
		support::assert_bytes(c.output(), "FF FF 00 00 00 06 01 03 00 00 00 0A", "TV-M6");
		feed_all(&c, support::hx("FF FF 00 00 00 17 01 03 14 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"));
		Event ev;
		assert(c.poll(at(1), &ev) && ev.kind == EventKind.RESPONSE && ev.tid == 0xFFFF);
		assert(c.send(&r, at(0))!! == 0);    // wraps to 0, a legal id
	};
}

// ---- write guard ----

fn void test_write_guard() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		char[300] scratch;
		bool[8] bits;
		ushort[1] reg = { 1 };
		Request[6] writes = {
			pdu::write_single_coil(0, true),
			pdu::write_single_register(0, 1),
			pdu::write_multiple_coils(0, &bits, &scratch)!!,
			pdu::write_multiple_registers(0, &reg, &scratch)!!,
			pdu::mask_write_register(0, 0xFF, 0x00),
			pdu::read_write_registers(0, 1, 0, &reg, &scratch)!!,
		};
		foreach (&w : writes)
		{
			assert(@catch(c.send(w, at(0))) == modbus::WRITE_NOT_ALLOWED, "fc %d", w.fc);
		}
		assert(c.output().len == 0 && c.pending_count() == 0);
		// reads and device identification stay available
		Request rd = read3();
		assert(c.send(&rd, at(0))!! == 1);
		Request id = pdu::read_device_id(1, 0);
		assert(c.send(&id, at(0))!! == 2);
		Request diag = { .fc = (char)Fc.DIAGNOSTICS, .sub = 0, .data = scratch[:2] };
		assert(c.send(&diag, at(0))!! == 3);
		Request sid = { .fc = (char)Fc.REPORT_SERVER_ID };
		assert(c.send(&sid, at(0))!! == 4);

		Client d;
		ClientConfig k = cfg(8);
		k.allow_write = true;
		d.init(k, mem)!!;
		defer d.free();
		foreach (&w : writes) d.send(w, at(0))!!;
		assert(d.pending_count() == 6);
	};
}

// ---- other functions through the client ----

fn void test_diagnostics_echo_through_client() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = { .fc = 8, .sub = 0, .data = support::hx("A5 37") };
		c.send(&r, at(0), 1)!!;
		support::assert_bytes(c.output(), "00 01 00 00 00 06 01 08 00 00 A5 37");
		feed_all(&c, support::hx("00 01 00 00 00 06 01 08 00 00 A5 37"));
		Event ev;
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.RESPONSE && ev.response.sub == 0);
		support::assert_bytes(ev.response.data, "A5 37");
		// a corrupted echo is reported
		c.send(&r, at(0), 2)!!;
		feed_all(&c, support::hx("00 02 00 00 00 06 01 08 00 00 A5 38"));
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.PROTOCOL_ERROR && ev.error == modbus::MISMATCH);
	};
}

fn void test_device_id_more_follows_without_progress() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		Request r = pdu::read_device_id(1, 0);
		c.send(&r, at(0), 1)!!;
		support::assert_bytes(c.output(), "00 01 00 00 00 05 01 2B 0E 01 00");
		// Y8: more follows, next object id 0: decodes; the loop that issues the next request decides
		feed_all(&c, support::hx("00 01 00 00 00 0C 01 2B 0E 01 01 FF 00 01 00 02 41 42"));
		Event ev;
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.RESPONSE && ev.response.more_follows && ev.response.next_object_id == 0);
		assert(ev.response.object_count == 1);
	};
}

fn void test_feed_backpressure() @test
{
	Client c;
	c.init(cfg(), mem)!!;
	defer c.free();
	char[1000] junk;
	usz taken = c.feed(&junk)!!;
	assert(taken == 2 * modbus::MAX_TCP_ADU);
	assert(c.feed(junk[:10])!! == 0);
}

// ---- RTU ----

fn ClientConfig rtu_cfg()
{
	ClientConfig k = client::default_config();
	k.framing = RTU;
	k.max_pending = 4;           // RTU always uses depth 1
	k.timeout = time::ms(500);
	return k;
}

fn void test_rtu_send_and_response() @test
{
	@pool()
	{
		Client c;
		c.init(rtu_cfg(), mem)!!;
		defer c.free();
		assert(c.pending.len == 1);
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 10);
		assert(c.send(&r, at(0), 5)!! == 0);
		support::assert_bytes(c.output(), "01 03 00 00 00 0A C5 CD", "R1");
		assert(@catch(c.send(&r, at(0))) == modbus::TOO_MANY_PENDING);
	};
}

fn void test_rtu_response_matched_by_unit_and_function() @test
{
	@pool()
	{
		Client c;
		c.init(rtu_cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0), 5)!!;
		support::assert_bytes(c.output(), "01 03 00 6B 00 03 74 17");
		c.feed_frame(support::hx("01 03 06 02 2B 00 00 00 64 05 7A"))!!;               // R12
		Event ev;
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.RESPONSE && ev.cookie == 5 && ev.response.reg(0) == 555 && ev.response.reg(2) == 100);
		assert(c.pending_count() == 0);
	};
}

fn void test_rtu_broadcast_creates_no_slot() @test
{
	@pool()
	{
		Client c;
		ClientConfig k = rtu_cfg();
		k.allow_write = true;
		c.init(k, mem)!!;
		defer c.free();
		Request w = pdu::write_single_register(1, 3);
		assert(c.send(&w, at(0), 1, 0)!! == 0);
		support::assert_bytes(c.output(), "00 06 00 01 00 03 99 DA", "R16");
		assert(c.pending_count() == 0);
		Clock dl;
		assert(!c.next_deadline(&dl));
		// a read cannot be broadcast
		Request r = read3();
		assert(@catch(c.send(&r, at(0), 1, 0)) == modbus::BAD_VALUE);
		// and the slot is still free for a normal request
		assert(c.send(&w, at(0), 2, 1)!! == 0);
		assert(c.pending_count() == 1);
	};
}

fn void test_rtu_bad_crc_and_timeout() @test
{
	@pool()
	{
		Client c;
		c.init(rtu_cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		c.send(&r, at(0), 5)!!;
		c.feed_frame(support::hx("01 03 06 02 2B 00 00 00 64 05 7B"))!!;               // bad CRC (XR2 style)
		Event ev;
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.PROTOCOL_ERROR && ev.error == modbus::BAD_CRC && !ev.fatal);
		assert(c.pending_count() == 1);          // the request stays pending and times out
		assert(!c.poll(at(499), &ev));
		assert(c.poll(at(500), &ev) && ev.kind == EventKind.TIMEOUT && ev.cookie == 5);
	};
}

fn void test_rtu_frame_for_nobody_and_exception() @test
{
	@pool()
	{
		Client c;
		c.init(rtu_cfg(), mem)!!;
		defer c.free();
		Request r = read3();
		// a frame while nothing is pending
		c.feed_frame(support::hx("01 83 02 C0 F1"))!!;
		Event ev;
		assert(c.poll(at(0), &ev));
		assert(ev.kind == EventKind.PROTOCOL_ERROR && ev.error == modbus::UNKNOWN_TRANSACTION && !ev.fatal);
		c.send(&r, at(0), 6)!!;
		// answer from another unit: not ours, request stays pending
		c.feed_frame(support::hx("02 83 02 30 F1"))!!;
		assert(c.poll(at(1), &ev));
		assert(ev.kind == EventKind.PROTOCOL_ERROR);
		assert(c.pending_count() == 1);
		c.feed_frame(support::hx("01 83 02 C0 F1"))!!;                                   // R7
		assert(c.poll(at(2), &ev));
		assert(ev.kind == EventKind.EXCEPTION && ev.response.exception == ExceptionCode.ILLEGAL_DATA_ADDRESS && ev.cookie == 6);
	};
}

fn void test_rtu_feed_rules() @test
{
	@pool()
	{
		Client c;
		c.init(rtu_cfg(), mem)!!;
		defer c.free();
		assert(@catch(c.feed(support::hx("00"))) == modbus::BAD_VALUE);
		c.feed_frame(support::hx("01 83 02 C0 F1"))!!;
		assert(@catch(c.feed_frame(support::hx("01 83 02 C0 F1"))) == modbus::OUTPUT_FULL);
		Client t;
		t.init(cfg(), mem)!!;
		defer t.free();
		assert(@catch(t.feed_frame(support::hx("01 83 02 C0 F1"))) == modbus::BAD_VALUE);
	};
}

// A failing second allocation must not leak the first one.
fn void test_init_failure_releases_the_slots() @test
{
	support::LimitedAllocator a = { .allowed = 1 };        // the slots succeed, the output buffer fails
	Client c;
	assert(!@ok(c.init(cfg(1), &a)));
	assert(a.live == 0, "the slots of a failed init were not released (%d live)", a.live);
	support::LimitedAllocator none = { .allowed = 0 };
	assert(!@ok(c.init(cfg(1), &none)));
	assert(none.live == 0);
	support::LimitedAllocator enough = { .allowed = 2 };
	c.init(cfg(1), &enough)!!;
	assert(enough.live == 2);
	c.free();
	assert(enough.live == 0);
}

// FC 8 sub-functions other than 0 change device state (restart, listen only, clear counters): they need allow_write.
fn void test_diagnostics_side_effects_need_allow_write() @test
{
	@pool()
	{
		Client c;
		c.init(cfg(), mem)!!;
		defer c.free();
		ushort[4] subs = { 0x0001, 0x0004, 0x000A, 0x0002 };
		foreach (s : subs)
		{
			Request r = { .fc = (char)Fc.DIAGNOSTICS, .sub = s, .data = support::hx("00 00") };
			assert(@catch(c.send(&r, at(0))) == modbus::WRITE_NOT_ALLOWED, "sub-function %d", s);
		}
		assert(c.output().len == 0 && c.pending_count() == 0);
		// return query data only echoes: allowed
		Request echo = { .fc = (char)Fc.DIAGNOSTICS, .sub = 0, .data = support::hx("A5 37") };
		assert(c.send(&echo, at(0))!! == 1);
		// with the guard open the side-effect functions go out
		Client d;
		ClientConfig k = cfg();
		k.allow_write = true;
		d.init(k, mem)!!;
		defer d.free();
		Request restart = { .fc = (char)Fc.DIAGNOSTICS, .sub = 1, .data = support::hx("00 00") };
		assert(d.send(&restart, at(0))!! == 1);
	};
}
