module modbus::pdu_misc_test;

import modbus;
import modbus::pdu;
import modbus::support;

fn fault dec_fault(String h)
{
	if (catch f = pdu::decode_request(support::hx(h))) return f;
	unreachable("decode unexpectedly succeeded");
}

// ---- FC 8 diagnostics ----

fn void test_fc8_request_and_echo() @test
{
	@pool()
	{
		Request r = pdu::decode_request(support::hx("08 00 00 A5 37"))!!;                          // V21
		assert(r.fc == 8 && r.sub == 0);
		support::assert_bytes(r.data, "A5 37");
		char[16] out;
		usz n = pdu::encode_request(&r, &out)!!;
		support::assert_bytes(out[:n], "08 00 00 A5 37");
		Response rsp = pdu::decode_response(&r, support::hx("08 00 00 A5 37"))!!;                  // V22
		assert(rsp.sub == 0 && !rsp.is_exception);
		support::assert_bytes(rsp.data, "A5 37");
		// the echo must repeat the request data
		assert(@catch(pdu::decode_response(&r, support::hx("08 00 00 A5 38"))) == modbus::MISMATCH);
		assert(@catch(pdu::decode_response(&r, support::hx("08 00 01 A5 37"))) == modbus::MISMATCH);
		// other sub-functions are not echoed: data is free
		Request other = { .fc = 8, .sub = 0x0001, .data = support::hx("00 00") };
		rsp = pdu::decode_response(&other, support::hx("08 00 01 FF 00"))!!;
		assert(rsp.sub == 1);
		Response er = { .fc = 8, .sub = 0, .data = support::hx("A5 37") };
		n = pdu::encode_response(&er, &out)!!;
		support::assert_bytes(out[:n], "08 00 00 A5 37", "V22");
	};
}

fn void test_fc8_lengths() @test
{
	@pool()
	{
		assert(dec_fault("08 00 00 12") == modbus::SHORT_FRAME);          // one data byte
		assert(dec_fault("08 00 00") == modbus::SHORT_FRAME);             // no data
		assert(dec_fault("08 00") == modbus::SHORT_FRAME);
		assert(dec_fault("08") == modbus::SHORT_FRAME);
		assert(dec_fault("08 00 00 12 34 56") == modbus::BAD_LENGTH);     // odd data length
		assert(pdu::decode_request(support::hx("08 00 00 12 34 56 78"))!!.data.len == 4);
		Request r = { .fc = 8, .sub = 0, .data = support::hx("12") };
		char[16] out;
		assert(@catch(pdu::encode_request(&r, &out)) == modbus::BAD_LENGTH);
		Request req = { .fc = 8, .sub = 0, .data = support::hx("A5 37") };
		assert(@catch(pdu::decode_response(&req, support::hx("08 00 00 A5"))) == modbus::SHORT_FRAME);
		assert(@catch(pdu::decode_response(&req, support::hx("08 00 00 A5 37 00"))) == modbus::BAD_LENGTH);
	};
}

// ---- FC 0x11 report server id ----

fn void test_fc17_server_id() @test
{
	@pool()
	{
		Request r = pdu::decode_request(support::hx("11"))!!;                                      // V23
		assert(r.fc == 0x11);
		char[8] out;
		usz n = pdu::encode_request(&r, &out)!!;
		support::assert_bytes(out[:n], "11");
		Response rsp = pdu::decode_response(&r, support::hx("11 04 01 FF 41 42"))!!;               // V24
		support::assert_bytes(rsp.data, "01 FF 41 42");
		rsp = pdu::decode_response(&r, support::hx("11 03 FF 00 01"))!!;
		assert(rsp.data.len == 3);
		assert(@catch(pdu::decode_response(&r, support::hx("11 04 01 FF 41"))) == modbus::TRUNCATED);
		assert(@catch(pdu::decode_response(&r, support::hx("11 02 01 FF 41"))) == modbus::BAD_LENGTH);
		assert(@catch(pdu::decode_response(&r, support::hx("11"))) == modbus::SHORT_FRAME);
		assert(dec_fault("11 00") == modbus::BAD_LENGTH);
		Response er = { .fc = 0x11, .data = support::hx("01 FF 41 42") };
		n = pdu::encode_response(&er, &out)!!;
		support::assert_bytes(out[:n], "11 04 01 FF 41 42", "V24");
	};
}

// ---- FC 43/14 read device identification ----

fn void test_fc43_request() @test
{
	@pool()
	{
		Request r = pdu::decode_request(support::hx("2B 0E 01 00"))!!;                             // V25
		assert(r.fc == 0x2B && r.sub == 0x0E && r.read_dev_code == 1 && r.object_id == 0);
		char[8] out;
		usz n = pdu::encode_request(&r, &out)!!;
		support::assert_bytes(out[:n], "2B 0E 01 00", "V25");
		r = pdu::decode_request(support::hx("2B 0E 04 05"))!!;                                     // V27
		assert(r.read_dev_code == 4 && r.object_id == 5);
		Request b = pdu::read_device_id(2, 7);
		n = pdu::encode_request(&b, &out)!!;
		support::assert_bytes(out[:n], "2B 0E 02 07");
		assert(pdu::decode_request(support::hx("2B 0E 04 FF"))!!.object_id == 0xFF);               // L25 decodes; the server answers 02
	};
}

fn void test_fc43_request_errors() @test
{
	@pool()
	{
		assert(dec_fault("2B 0E 05 00") == modbus::BAD_VALUE);            // L23
		assert(dec_fault("2B 0E 00 00") == modbus::BAD_VALUE);            // L24
		assert(dec_fault("2B 0D 00 00") == modbus::UNSUPPORTED_FUNCTION); // L26
		assert(dec_fault("2B 0E 01") == modbus::SHORT_FRAME);             // L27
		assert(dec_fault("2B 0E") == modbus::SHORT_FRAME);
		assert(dec_fault("2B") == modbus::SHORT_FRAME);
		assert(dec_fault("2B 0E 01 00 00") == modbus::BAD_LENGTH);
		assert(pdu::fault_to_exception(modbus::BAD_VALUE) == ExceptionCode.ILLEGAL_DATA_VALUE);
		assert(pdu::fault_to_exception(modbus::UNSUPPORTED_FUNCTION) == ExceptionCode.ILLEGAL_FUNCTION);
	};
}

fn void test_fc43_response_objects() @test
{
	@pool()
	{
		Request rq = pdu::read_device_id(1, 0);
		Response rsp = pdu::decode_response(&rq, support::hx("2B 0E 01 01 00 00 03 00 03 41 42 43 01 02 58 59 02 03 31 2E 30"))!!;   // V26
		assert(rsp.conformity == 1 && !rsp.more_follows && rsp.next_object_id == 0 && rsp.object_count == 3);
		pdu::ObjectIter it = pdu::objects(&rsp);
		pdu::DeviceObject o;
		assert(it.next(&o)!!);
		assert(o.id == 0 && o.value == "ABC");
		assert(it.next(&o)!!);
		assert(o.id == 1 && o.value == "XY");
		assert(it.next(&o)!!);
		assert(o.id == 2 && o.value == "1.0");
		assert(!it.next(&o)!!);

		rsp = pdu::decode_response(&rq, support::hx("2B 0E 01 01 00 00 03 00 03 41 42 43 01 02 58 59 02 01 5A"))!!;   // objects ABC, XY, Z
		it = pdu::objects(&rsp);
		assert(it.next(&o)!! && it.next(&o)!! && it.next(&o)!!);
		assert(o.id == 2 && o.value == "Z");

		Request rq4 = pdu::read_device_id(4, 5);
		rsp = pdu::decode_response(&rq4, support::hx("2B 0E 04 81 00 00 01 05 02 4D 31"))!!;                           // V28
		assert(rsp.conformity == 0x81 && rsp.read_dev_code == 4 && rsp.object_count == 1);
		it = pdu::objects(&rsp);
		assert(it.next(&o)!!);
		assert(o.id == 5 && o.value == "M1");

		rsp = pdu::decode_response(&rq, support::hx("2B 0E 01 81 FF 02 01 00 02 41 42"))!!;                             // V29
		assert(rsp.more_follows && rsp.next_object_id == 2 && rsp.object_count == 1);
		// no progress (next id 0 although more follows) decodes fine: the loop that sends the next request decides (Y8)
		rsp = pdu::decode_response(&rq, support::hx("2B 0E 01 01 FF 00 01 00 02 41 42"))!!;
		assert(rsp.more_follows && rsp.next_object_id == 0);
		// no objects at all is legal
		rsp = pdu::decode_response(&rq, support::hx("2B 0E 01 01 00 00 00"))!!;
		assert(rsp.object_count == 0 && rsp.data.len == 0);
	};
}

fn void test_fc43_response_errors() @test
{
	@pool()
	{
		Request rq = pdu::read_device_id(1, 0);
		// Y9: object 0 says length 3 but has 2 data bytes
		assert(@catch(pdu::decode_response(&rq, support::hx("2B 0E 01 01 00 00 03 00 03 41 42"))) == modbus::TRUNCATED);
		// Y10: two objects announced, one present
		assert(@catch(pdu::decode_response(&rq, support::hx("2B 0E 01 01 00 00 02 00 01 41"))) == modbus::TRUNCATED);
		// fewer objects announced than present: trailing bytes
		assert(@catch(pdu::decode_response(&rq, support::hx("2B 0E 01 01 00 00 01 00 01 41 01 01 42"))) == modbus::BAD_LENGTH);
		// echoed code differs
		assert(@catch(pdu::decode_response(&rq, support::hx("2B 0E 02 01 00 00 00"))) == modbus::MISMATCH);
		// wrong MEI type
		assert(@catch(pdu::decode_response(&rq, support::hx("2B 0D 01 01 00 00 00"))) == modbus::MISMATCH);
		// more-follows byte is 0x00 or 0xFF only
		assert(@catch(pdu::decode_response(&rq, support::hx("2B 0E 01 01 01 00 00"))) == modbus::BAD_VALUE);
		// header cut short
		assert(@catch(pdu::decode_response(&rq, support::hx("2B 0E 01 01 00 00"))) == modbus::SHORT_FRAME);
		// object header cut at the end
		assert(@catch(pdu::decode_response(&rq, support::hx("2B 0E 01 01 00 00 01 00"))) == modbus::TRUNCATED);
		// exception 2B: illegal function 01 (V32)
		Response e = pdu::decode_response(&rq, support::hx("AB 01"))!!;
		assert(e.is_exception && e.fc == 0x2B && e.exception == ExceptionCode.ILLEGAL_FUNCTION);
	};
}

fn void test_fc43_encode_response() @test
{
	@pool()
	{
		char[260] out;
		char[] objs = support::hx("00 03 41 42 43 01 02 58 59 02 03 31 2E 30");
		Response r = { .fc = 0x2B, .read_dev_code = 1, .conformity = 1, .object_count = 3, .data = objs };
		usz n = pdu::encode_response(&r, &out)!!;
		support::assert_bytes(out[:n], "2B 0E 01 01 00 00 03 00 03 41 42 43 01 02 58 59 02 03 31 2E 30", "V26");
		r = { .fc = 0x2B, .read_dev_code = 1, .conformity = 0x81, .more_follows = true, .next_object_id = 2, .object_count = 1, .data = support::hx("00 02 41 42") };
		n = pdu::encode_response(&r, &out)!!;
		support::assert_bytes(out[:n], "2B 0E 01 81 FF 02 01 00 02 41 42", "V29");
		// the announced count must match the object bytes
		r.object_count = 2;
		assert(@catch(pdu::encode_response(&r, &out)) == modbus::TRUNCATED);
		r.object_count = 0;
		assert(@catch(pdu::encode_response(&r, &out)) == modbus::BAD_LENGTH);
	};
}

fn void test_object_iter_truncated() @test
{
	@pool()
	{
		Response rsp = { .data = support::hx("00 03 41 42") };
		pdu::ObjectIter it = pdu::objects(&rsp);
		pdu::DeviceObject o;
		assert(@catch(it.next(&o)) == modbus::TRUNCATED);
		Response one = { .data = support::hx("00") };
		it = pdu::objects(&one);
		assert(@catch(it.next(&o)) == modbus::TRUNCATED);
	};
}
