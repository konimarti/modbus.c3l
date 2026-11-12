module modbus::pdu_read_test;

import modbus;
import modbus::pdu;
import modbus::support;

// Decoded request of a hex PDU.
fn Request req(String h)
{
	return pdu::decode_request(support::hx(h))!!;
}

// ---- requests: V1, V3, V5, V7, V9, V11 ----

fn void test_decode_read_requests() @test
{
	@pool()
	{
		Request r = req("01 00 13 00 13");                       // V1
		assert(r.fc == 1 && r.addr == 19 && r.qty == 19);
		r = req("02 00 C4 00 16");                               // V3
		assert(r.fc == 2 && r.addr == 196 && r.qty == 22);
		r = req("03 00 6B 00 03");                               // V5
		assert(r.fc == 3 && r.addr == 107 && r.qty == 3);
		r = req("04 00 08 00 01");                               // V7
		assert(r.fc == 4 && r.addr == 8 && r.qty == 1);
	};
}

fn void test_decode_write_single_requests() @test
{
	@pool()
	{
		Request r = req("05 00 AC FF 00");                       // V9
		assert(r.fc == 5 && r.addr == 172 && r.value == 0xFF00);
		r = req("05 00 AC 00 00");
		assert(r.value == 0);
		r = req("06 00 01 00 03");                               // V11
		assert(r.fc == 6 && r.addr == 1 && r.value == 3);
		r = req("06 FF FF FF FF");                               // any register value is legal
		assert(r.addr == 0xFFFF && r.value == 0xFFFF);
	};
}

fn void test_encode_requests_roundtrip() @test
{
	@pool()
	{
		char[8] out;
		Request r = pdu::read_request(Fc.READ_COILS, 19, 19);
		usz n = pdu::encode_request(&r, &out)!!;
		support::assert_bytes(out[:n], "01 00 13 00 13", "V1");
		r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 107, 3);
		n = pdu::encode_request(&r, &out)!!;
		support::assert_bytes(out[:n], "03 00 6B 00 03", "V5");
		r = pdu::write_single_coil(172, true);
		n = pdu::encode_request(&r, &out)!!;
		support::assert_bytes(out[:n], "05 00 AC FF 00", "V9");
		r = pdu::write_single_coil(172, false);
		n = pdu::encode_request(&r, &out)!!;
		support::assert_bytes(out[:n], "05 00 AC 00 00");
		r = pdu::write_single_register(1, 3);
		n = pdu::encode_request(&r, &out)!!;
		support::assert_bytes(out[:n], "06 00 01 00 03", "V11");
		// every encoded request decodes to the same fields
		Request d = pdu::decode_request(out[:n])!!;
		assert(d.fc == 6 && d.addr == 1 && d.value == 3);
	};
}

fn void test_encode_request_checks() @test
{
	char[8] out;
	char[4] small;
	Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 126);
	assert(@catch(pdu::encode_request(&r, &out)) == modbus::BAD_QUANTITY);
	r = pdu::read_request(Fc.READ_COILS, 0, 0);
	assert(@catch(pdu::encode_request(&r, &out)) == modbus::BAD_QUANTITY);
	r = pdu::read_request(Fc.READ_COILS, 0xFFFF, 2);
	assert(@catch(pdu::encode_request(&r, &out)) == modbus::BAD_ADDRESS_RANGE);
	r = pdu::read_request(Fc.READ_COILS, 0, 1);
	assert(@catch(pdu::encode_request(&r, &small)) == modbus::BUFFER_TOO_SMALL);
	r = pdu::write_single_coil(0, true);
	r.value = 0x1234;
	assert(@catch(pdu::encode_request(&r, &out)) == modbus::BAD_VALUE);
	r.fc = 0x41;
	assert(@catch(pdu::encode_request(&r, &out)) == modbus::UNSUPPORTED_FUNCTION);
}

// ---- request limits: L1 to L10 ----

fn void test_request_limits() @test
{
	@pool()
	{
		assert(@catch(pdu::decode_request(support::hx("01 00 00 00 00"))) == modbus::BAD_QUANTITY);   // L1
		assert(@catch(pdu::decode_request(support::hx("01 00 00 07 D1"))) == modbus::BAD_QUANTITY);   // L2
		assert(pdu::decode_request(support::hx("01 00 00 07 D0"))!!.qty == 2000);                     // L3
		assert(@catch(pdu::decode_request(support::hx("03 00 00 00 00"))) == modbus::BAD_QUANTITY);   // L4
		assert(@catch(pdu::decode_request(support::hx("03 00 00 00 7E"))) == modbus::BAD_QUANTITY);   // L5
		assert(pdu::decode_request(support::hx("03 00 00 00 7D"))!!.qty == 125);                      // L6
		assert(@catch(pdu::decode_request(support::hx("03 FF FF 00 02"))) == modbus::BAD_ADDRESS_RANGE); // L7
		assert(pdu::decode_request(support::hx("03 FF FF 00 01"))!!.addr == 0xFFFF);                  // L8
		assert(@catch(pdu::decode_request(support::hx("05 00 01 00 01"))) == modbus::BAD_VALUE);      // L9
		assert(@catch(pdu::decode_request(support::hx("05 00 01 FF FF"))) == modbus::BAD_VALUE);      // L10
		// FC 4 and FC 2 share the limits of their group
		assert(@catch(pdu::decode_request(support::hx("04 00 00 00 7E"))) == modbus::BAD_QUANTITY);
		assert(@catch(pdu::decode_request(support::hx("02 00 00 07 D1"))) == modbus::BAD_QUANTITY);
		assert(pdu::decode_request(support::hx("02 00 00 07 D0"))!!.qty == 2000);
		// the quantity is checked before the address range
		assert(@catch(pdu::decode_request(support::hx("03 FF FF 00 00"))) == modbus::BAD_QUANTITY);
		assert(@catch(pdu::decode_request(support::hx("03 FF FF 00 7E"))) == modbus::BAD_QUANTITY);
		// address range at the edge: 0xFFFF0 + ... : 0xFF83 + 125 = 0x10000
		assert(pdu::decode_request(support::hx("03 FF 83 00 7D"))!!.qty == 125);
		assert(@catch(pdu::decode_request(support::hx("03 FF 84 00 7D"))) == modbus::BAD_ADDRESS_RANGE);
	};
}

// ---- malformed requests: L28 to L36 (decode level) and more ----

fn void test_malformed_requests() @test
{
	@pool()
	{
		char[] none = {};
		assert(@catch(pdu::decode_request(none)) == modbus::SHORT_FRAME);                              // L31
		char[254] big;
		big[0] = 3;
		assert(@catch(pdu::decode_request(&big)) == modbus::BAD_LENGTH);                              // L32
		assert(@catch(pdu::decode_request(support::hx("03 00 6B 00"))) == modbus::SHORT_FRAME);       // L33
		assert(@catch(pdu::decode_request(support::hx("03 00 6B 00 03 00"))) == modbus::BAD_LENGTH);  // L34
		assert(@catch(pdu::decode_request(support::hx("83"))) == modbus::UNSUPPORTED_FUNCTION);       // L35 as a request
		assert(@catch(pdu::decode_request(support::hx("83 02 00"))) == modbus::UNSUPPORTED_FUNCTION); // L36 as a request
		assert(@catch(pdu::decode_request(support::hx("41 00 00"))) == modbus::UNSUPPORTED_FUNCTION); // L30
		assert(@catch(pdu::decode_request(support::hx("00 00 01"))) == modbus::UNSUPPORTED_FUNCTION); // L28: fc 0
		assert(@catch(pdu::decode_request(support::hx("80 00"))) == modbus::UNSUPPORTED_FUNCTION);    // L29
		// every truncation of every request is a fault
		String[] msgs = { "01 00 13 00 13", "03 00 6B 00 03", "05 00 AC FF 00", "06 00 01 00 03" };
		foreach (m : msgs)
		{
			char[] full = support::hx(m);
			for (usz cut = 0; cut < full.len; cut++)
			{
				assert(!@ok(pdu::decode_request(full[:cut])), "cut %d of %s", cut, m);
			}
		}
	};
}

fn void test_fault_to_exception() @test
{
	assert(pdu::fault_to_exception(modbus::UNSUPPORTED_FUNCTION) == ExceptionCode.ILLEGAL_FUNCTION);
	assert(pdu::fault_to_exception(modbus::BAD_ADDRESS_RANGE) == ExceptionCode.ILLEGAL_DATA_ADDRESS);
	assert(pdu::fault_to_exception(modbus::BAD_QUANTITY) == ExceptionCode.ILLEGAL_DATA_VALUE);
	assert(pdu::fault_to_exception(modbus::BAD_BYTE_COUNT) == ExceptionCode.ILLEGAL_DATA_VALUE);
	assert(pdu::fault_to_exception(modbus::BAD_VALUE) == ExceptionCode.ILLEGAL_DATA_VALUE);
	assert(pdu::fault_to_exception(modbus::SHORT_FRAME) == ExceptionCode.ILLEGAL_DATA_VALUE);
	assert(pdu::fault_to_exception(modbus::BAD_LENGTH) == ExceptionCode.ILLEGAL_DATA_VALUE);
}

// ---- responses: V2, V4, V6, V8, V10, V12 ----

fn void test_decode_coil_response() @test
{
	@pool()
	{
		Request rq = pdu::read_request(Fc.READ_COILS, 19, 19);
		Response rsp = pdu::decode_response(&rq, support::hx("01 03 CD 6B 05"))!!;     // V2
		assert(!rsp.is_exception && rsp.fc == 1);
		support::assert_bytes(rsp.data, "CD 6B 05");
		// CD = 1100 1101: first coil is bit 0
		bool[19] want = { true, false, true, true, false, false, true, true,   // CD
			true, true, false, true, false, true, true, false,                 // 6B
			true, false, true };                                               // 05 (3 bits used)
		for (usz i = 0; i < 19; i++) assert(rsp.coil(i) == want[i], "coil %d", i);
		bool[19] copy;
		rsp.copy_coils(&copy)!!;
		assert(copy == want);
		bool[5] short_out;
		assert(@catch(rsp.copy_coils(&short_out)) == modbus::SHORT_REGISTERS);
	};
}

fn void test_coil_padding_bits_ignored() @test
{
	@pool()
	{
		// 10 coils asked, last byte carries garbage in bits 2..7
		Request rq = pdu::read_request(Fc.READ_COILS, 0, 10);
		Response rsp = pdu::decode_response(&rq, support::hx("01 02 01 FF"))!!;
		assert(rsp.coil(0) && !rsp.coil(1));
		assert(rsp.coil(8) && rsp.coil(9));
		assert(!rsp.coil(10) && !rsp.coil(15));
		bool[10] copy;
		rsp.copy_coils(&copy)!!;
		assert(copy[9] && copy[8]);
	};
}

fn void test_decode_discrete_response() @test
{
	@pool()
	{
		Request rq = pdu::read_request(Fc.READ_DISCRETE_INPUTS, 196, 22);
		Response rsp = pdu::decode_response(&rq, support::hx("02 03 AC DB 35"))!!;     // V4
		assert(rsp.fc == 2);
		support::assert_bytes(rsp.data, "AC DB 35");
		assert(!rsp.coil(0) && !rsp.coil(1) && rsp.coil(2) && rsp.coil(3));            // AC = 1010 1100
		assert(!rsp.coil(22));
	};
}

fn void test_decode_register_responses() @test
{
	@pool()
	{
		Request rq = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 107, 3);
		Response rsp = pdu::decode_response(&rq, support::hx("03 06 02 2B 00 00 00 64"))!!;  // V6
		assert(rsp.reg_count() == 3);
		assert(rsp.reg(0) == 555 && rsp.reg(1) == 0 && rsp.reg(2) == 100);
		assert(rsp.reg(3) == 0);
		ushort[3] regs;
		rsp.copy_regs(&regs)!!;
		assert(regs[0] == 0x022B && regs[2] == 0x0064);
		ushort[2] short_out;
		assert(@catch(rsp.copy_regs(&short_out)) == modbus::SHORT_REGISTERS);

		rq = pdu::read_request(Fc.READ_INPUT_REGISTERS, 8, 1);
		rsp = pdu::decode_response(&rq, support::hx("04 02 00 0A"))!!;                          // V8
		assert(rsp.fc == 4 && rsp.reg(0) == 10);
	};
}

fn void test_decode_write_single_responses() @test
{
	@pool()
	{
		Request rq = pdu::write_single_coil(172, true);
		Response rsp = pdu::decode_response(&rq, support::hx("05 00 AC FF 00"))!!;      // V10
		assert(rsp.addr == 172 && rsp.value == 0xFF00 && !rsp.is_exception);
		rq = pdu::write_single_register(1, 3);
		rsp = pdu::decode_response(&rq, support::hx("06 00 01 00 03"))!!;               // V12
		assert(rsp.addr == 1 && rsp.value == 3);
	};
}

fn void test_encode_responses() @test
{
	@pool()
	{
		char[260] out;
		Response r = { .fc = 3, .data = support::hx("02 2B 00 00 00 64") };
		usz n = pdu::encode_response(&r, &out)!!;
		support::assert_bytes(out[:n], "03 06 02 2B 00 00 00 64", "V6");
		r = { .fc = 1, .data = support::hx("CD 6B 05") };
		n = pdu::encode_response(&r, &out)!!;
		support::assert_bytes(out[:n], "01 03 CD 6B 05", "V2");
		r = { .fc = 5, .addr = 172, .value = 0xFF00 };
		n = pdu::encode_response(&r, &out)!!;
		support::assert_bytes(out[:n], "05 00 AC FF 00", "V10");
		r = { .fc = 6, .addr = 1, .value = 3 };
		n = pdu::encode_response(&r, &out)!!;
		support::assert_bytes(out[:n], "06 00 01 00 03", "V12");
		// exception
		r = { .fc = 3, .is_exception = true, .exception = ExceptionCode.ILLEGAL_DATA_ADDRESS };
		n = pdu::encode_response(&r, &out)!!;
		support::assert_bytes(out[:n], "83 02", "V31");
		// odd register byte count, empty data
		r = { .fc = 3, .data = support::hx("01 02 03") };
		assert(@catch(pdu::encode_response(&r, &out)) == modbus::BAD_BYTE_COUNT);
		r = { .fc = 1 };
		assert(@catch(pdu::encode_response(&r, &out)) == modbus::BAD_BYTE_COUNT);
		char[3] small;
		r = { .fc = 5 };
		assert(@catch(pdu::encode_response(&r, &small)) == modbus::BUFFER_TOO_SMALL);
		r = { .fc = 0x41 };
		assert(@catch(pdu::encode_response(&r, &out)) == modbus::UNSUPPORTED_FUNCTION);
	};
}

fn void test_largest_read_response() @test
{
	// FC 3 with 125 registers is the longest read response: 2 + 250 = 252 bytes
	char[250] regs;
	char[260] out;
	Response r = { .fc = 3, .data = &regs };
	assert(pdu::encode_response(&r, &out)!! == 252);
	Request rq = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 125);
	Response d = pdu::decode_response(&rq, out[:252])!!;
	assert(d.reg_count() == 125);
}

// ---- exceptions: V30, V31, V32 and raw codes ----

fn void test_exception_responses() @test
{
	@pool()
	{
		Request rq = pdu::read_request(Fc.READ_COILS, 0, 1);
		Response rsp = pdu::decode_response(&rq, support::hx("81 02"))!!;                // V30
		assert(rsp.is_exception && rsp.fc == 1 && rsp.exception == ExceptionCode.ILLEGAL_DATA_ADDRESS);
		rq = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		rsp = pdu::decode_response(&rq, support::hx("83 02"))!!;                         // V31
		assert(rsp.is_exception && rsp.fc == 3 && rsp.exception == ExceptionCode.ILLEGAL_DATA_ADDRESS);
		rsp = pdu::decode_response(&rq, support::hx("83 01"))!!;
		assert(rsp.exception == ExceptionCode.ILLEGAL_FUNCTION);
		rq = pdu::write_single_register(0, 1);
		rsp = pdu::decode_response(&rq, support::hx("86 06"))!!;
		assert(rsp.is_exception && rsp.exception == ExceptionCode.SERVER_DEVICE_BUSY);
	};
}

fn void test_exception_raw_codes() @test
{
	@pool()
	{
		Request rq = pdu::read_request(Fc.READ_COILS, 0, 1);
		Response rsp = pdu::decode_response(&rq, support::hx("81 00"))!!;                // code 0 is legal on the wire
		assert(rsp.is_exception);
		assert((char)rsp.exception == 0);
		rq = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		rsp = pdu::decode_response(&rq, support::hx("83 07"))!!;                         // NEGATIVE ACKNOWLEDGE, not in the enum
		assert(rsp.is_exception && (char)rsp.exception == 7);
		rsp = pdu::decode_response(&rq, support::hx("83 FF"))!!;                         // vendor code
		assert(rsp.is_exception && (char)rsp.exception == 0xFF);
		// a normal reply is not an exception
		rsp = pdu::decode_response(&rq, support::hx("03 02 00 01"))!!;
		assert(!rsp.is_exception);
	};
}

fn void test_exception_malformed() @test
{
	@pool()
	{
		Request rq = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
		assert(@catch(pdu::decode_response(&rq, support::hx("83"))) == modbus::SHORT_FRAME);          // L35
		assert(@catch(pdu::decode_response(&rq, support::hx("83 02 00"))) == modbus::BAD_LENGTH);     // L36
		assert(@catch(pdu::decode_response(&rq, support::hx("81 02"))) == modbus::MISMATCH);          // other function
		char[] none = {};
		assert(@catch(pdu::decode_response(&rq, none)) == modbus::SHORT_FRAME);
		char[254] big;
		big[0] = 3;
		assert(@catch(pdu::decode_response(&rq, &big)) == modbus::BAD_LENGTH);
	};
}

// ---- response-side malformed input: Y1 to Y7 ----

fn void test_malformed_responses() @test
{
	@pool()
	{
		Request rq3 = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 3);
		assert(@catch(pdu::decode_response(&rq3, support::hx("03 06 02 2B 00 00 00"))) == modbus::TRUNCATED);      // Y1
		assert(@catch(pdu::decode_response(&rq3, support::hx("03 05 02 2B 00 00 00"))) == modbus::BAD_BYTE_COUNT); // Y2
		assert(@catch(pdu::decode_response(&rq3, support::hx("03 04 02 2B 00 00"))) == modbus::BAD_BYTE_COUNT);    // Y3
		Request rq1 = pdu::read_request(Fc.READ_COILS, 0, 19);
		assert(@catch(pdu::decode_response(&rq1, support::hx("01 02 CD 6B"))) == modbus::BAD_BYTE_COUNT);          // Y4
		Request rq5 = pdu::write_single_coil(172, true);
		assert(@catch(pdu::decode_response(&rq5, support::hx("05 00 AC 00 00"))) == modbus::MISMATCH);            // Y5
		Request rq16 = pdu::write_single_register(1, 3);
		assert(@catch(pdu::decode_response(&rq16, support::hx("06 00 01 00 04"))) == modbus::MISMATCH);
		assert(@catch(pdu::decode_response(&rq16, support::hx("06 00 02 00 03"))) == modbus::MISMATCH);
		// Y6 is a write-multiple vector (checked with the next function group); Y7:
		assert(@catch(pdu::decode_response(&rq3, support::hx("04 02 00 0A"))) == modbus::MISMATCH);               // Y7
		// trailing byte after a complete response
		assert(@catch(pdu::decode_response(&rq3, support::hx("03 06 02 2B 00 00 00 64 00"))) == modbus::BAD_LENGTH);
		// every truncation of every response is a fault
		String[] msgs = { "03 06 02 2B 00 00 00 64" };
		foreach (m : msgs)
		{
			char[] full = support::hx(m);
			for (usz cut = 0; cut < full.len; cut++)
			{
				assert(!@ok(pdu::decode_response(&rq3, full[:cut])), "cut %d of %s", cut, m);
			}
		}
		char[] coils = support::hx("01 03 CD 6B 05");
		for (usz cut = 0; cut < coils.len; cut++)
		{
			assert(!@ok(pdu::decode_response(&rq1, coils[:cut])), "coil cut %d", cut);
		}
		// unsupported function in this step
		Request rq = { .fc = 0x41 };
		assert(@catch(pdu::decode_response(&rq, support::hx("41 00"))) == modbus::UNSUPPORTED_FUNCTION);
	};
}

fn void test_encode_exception() @test
{
	char[2] out;
	assert(pdu::encode_exception(3, ExceptionCode.ILLEGAL_DATA_ADDRESS, &out) == 2);
	assert(out[0] == 0x83 && out[1] == 2);
	assert(pdu::encode_exception(0x2B, ExceptionCode.ILLEGAL_FUNCTION, &out) == 2);   // V32
	assert(out[0] == 0xAB && out[1] == 1);
	char[1] tiny;
	assert(pdu::encode_exception(3, ExceptionCode.ILLEGAL_FUNCTION, &tiny) == 0);
}
