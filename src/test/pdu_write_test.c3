module modbus::pdu_write_test;

import modbus;
import modbus::pdu;
import modbus::support;

// Fault of decoding a request; the test fails when decoding succeeds.
fn fault dec_fault(char[] pdu)
{
	if (catch f = pdu::decode_request(pdu)) return f;
	unreachable("decode unexpectedly succeeded");
}

fn void test_decode_fc15() @test
{
	@pool()
	{
		Request r = pdu::decode_request(support::hx("0F 00 13 00 0A 02 CD 01"))!!;              // V13
		assert(r.fc == 0x0F && r.addr == 19 && r.qty == 10);
		support::assert_bytes(r.data, "CD 01");
	};
}

fn void test_decode_fc16() @test
{
	@pool()
	{
		Request r = pdu::decode_request(support::hx("10 00 01 00 02 04 00 0A 01 02"))!!;        // V15
		assert(r.fc == 0x10 && r.addr == 1 && r.qty == 2);
		support::assert_bytes(r.data, "00 0A 01 02");
	};
}

fn void test_decode_fc22() @test
{
	@pool()
	{
		Request r = pdu::decode_request(support::hx("16 00 04 00 F2 00 25"))!!;                  // V17
		assert(r.fc == 0x16 && r.addr == 4 && r.and_mask == 0x00F2 && r.or_mask == 0x0025);
	};
}

fn void test_decode_fc23() @test
{
	@pool()
	{
		Request r = pdu::decode_request(support::hx("17 00 03 00 06 00 0E 00 03 06 12 34 56 78 9A BC"))!!;   // V19
		assert(r.fc == 0x17 && r.addr == 3 && r.qty == 6 && r.write_addr == 14 && r.write_qty == 3);
		support::assert_bytes(r.data, "12 34 56 78 9A BC");
	};
}

fn void test_builders_and_encode() @test
{
	@pool()
	{
		char[260] out;
		char[16] scratch;
		bool[10] bits = { true, false, true, true, false, false, true, true, true, false };
		Request r = pdu::write_multiple_coils(19, &bits, &scratch)!!;
		usz n = pdu::encode_request(&r, &out)!!;
		support::assert_bytes(out[:n], "0F 00 13 00 0A 02 CD 01", "V13");

		ushort[2] regs = { 0x000A, 0x0102 };
		r = pdu::write_multiple_registers(1, &regs, &scratch)!!;
		n = pdu::encode_request(&r, &out)!!;
		support::assert_bytes(out[:n], "10 00 01 00 02 04 00 0A 01 02", "V15");

		r = pdu::mask_write_register(4, 0x00F2, 0x0025);
		n = pdu::encode_request(&r, &out)!!;
		support::assert_bytes(out[:n], "16 00 04 00 F2 00 25", "V17");

		ushort[3] w = { 0x1234, 0x5678, 0x9ABC };
		r = pdu::read_write_registers(3, 6, 14, &w, &scratch)!!;
		n = pdu::encode_request(&r, &out)!!;
		support::assert_bytes(out[:n], "17 00 03 00 06 00 0E 00 03 06 12 34 56 78 9A BC", "V19");

		// FC 15 packing: a 9-bit write sets only bit 0 of the second byte
		bool[9] nine = { true, true, true, true, true, true, true, true, true };
		r = pdu::write_multiple_coils(0, &nine, &scratch)!!;
		support::assert_bytes(r.data, "FF 01", "unused bits are zero");
		// 1 coil
		bool[1] one = { true };
		r = pdu::write_multiple_coils(0, &one, &scratch)!!;
		support::assert_bytes(r.data, "01");
	};
}

fn void test_builder_limits() @test
{
	char[300] scratch;
	bool[1969] too_many_bits;
	bool[1968] max_bits;
	bool[] no_bits = {};
	assert(@catch(pdu::write_multiple_coils(0, &too_many_bits, &scratch)) == modbus::BAD_QUANTITY);
	assert(@catch(pdu::write_multiple_coils(0, no_bits, &scratch)) == modbus::BAD_QUANTITY);
	assert(pdu::write_multiple_coils(0, &max_bits, &scratch)!!.qty == 1968);
	char[10] tiny;
	assert(@catch(pdu::write_multiple_coils(0, &max_bits, &tiny)) == modbus::BUFFER_TOO_SMALL);

	ushort[124] too_many_regs;
	ushort[123] max_regs;
	ushort[] no_regs = {};
	assert(@catch(pdu::write_multiple_registers(0, &too_many_regs, &scratch)) == modbus::BAD_QUANTITY);
	assert(@catch(pdu::write_multiple_registers(0, no_regs, &scratch)) == modbus::BAD_QUANTITY);
	assert(pdu::write_multiple_registers(0, &max_regs, &scratch)!!.qty == 123);
	assert(@catch(pdu::write_multiple_registers(0, &max_regs, &tiny)) == modbus::BUFFER_TOO_SMALL);

	ushort[122] rw_too_many;
	ushort[121] rw_max;
	assert(@catch(pdu::read_write_registers(0, 1, 0, &rw_too_many, &scratch)) == modbus::BAD_QUANTITY);
	assert(@catch(pdu::read_write_registers(0, 126, 0, &rw_max, &scratch)) == modbus::BAD_QUANTITY);
	assert(@catch(pdu::read_write_registers(0, 0, 0, &rw_max, &scratch)) == modbus::BAD_QUANTITY);
	assert(pdu::read_write_registers(0, 125, 0, &rw_max, &scratch)!!.write_qty == 121);
	assert(@catch(pdu::read_write_registers(0, 1, 0, &rw_max, &tiny)) == modbus::BUFFER_TOO_SMALL);
}

fn void test_longest_requests_fit() @test
{
	char[300] scratch;
	char[260] out;
	bool[1968] bits;
	ushort[123] regs;
	ushort[121] rw;
	Request r = pdu::write_multiple_coils(0, &bits, &scratch)!!;
	assert(pdu::encode_request(&r, &out)!! == 252);
	assert(pdu::decode_request(out[:252])!!.qty == 1968);
	r = pdu::write_multiple_registers(0, &regs, &scratch)!!;
	assert(pdu::encode_request(&r, &out)!! == 252);
	assert(pdu::decode_request(out[:252])!!.qty == 123);
	r = pdu::read_write_registers(0, 125, 0, &rw, &scratch)!!;
	assert(pdu::encode_request(&r, &out)!! == 252);
	assert(pdu::decode_request(out[:252])!!.write_qty == 121);
}

// ---- responses ----

fn void test_write_responses() @test
{
	@pool()
	{
		char[8] scratch;
		bool[10] bits;
		Request r = pdu::write_multiple_coils(19, &bits, &scratch)!!;
		Response rsp = pdu::decode_response(&r, support::hx("0F 00 13 00 0A"))!!;               // V14
		assert(rsp.addr == 19 && rsp.qty == 10 && !rsp.is_exception);

		ushort[2] regs = { 0x000A, 0x0102 };
		r = pdu::write_multiple_registers(1, &regs, &scratch)!!;
		rsp = pdu::decode_response(&r, support::hx("10 00 01 00 02"))!!;                        // V16
		assert(rsp.addr == 1 && rsp.qty == 2);
		assert(@catch(pdu::decode_response(&r, support::hx("10 00 01 00 03"))) == modbus::MISMATCH);   // Y6
		assert(@catch(pdu::decode_response(&r, support::hx("10 00 02 00 02"))) == modbus::MISMATCH);

		r = pdu::mask_write_register(4, 0x00F2, 0x0025);
		rsp = pdu::decode_response(&r, support::hx("16 00 04 00 F2 00 25"))!!;                  // V18
		assert(rsp.addr == 4 && rsp.and_mask == 0xF2 && rsp.or_mask == 0x25);
		assert(@catch(pdu::decode_response(&r, support::hx("16 00 04 00 F2 00 26"))) == modbus::MISMATCH);
		assert(@catch(pdu::decode_response(&r, support::hx("16 00 04 00 F2"))) == modbus::SHORT_FRAME);

		ushort[3] w = { 0x1234, 0x5678, 0x9ABC };
		char[16] sc2;
		r = pdu::read_write_registers(3, 6, 14, &w, &sc2)!!;
		rsp = pdu::decode_response(&r, support::hx("17 0C 00 FE 0A CD 00 01 00 03 00 0D 00 FF"))!!;     // V20
		assert(rsp.reg_count() == 6);
		assert(rsp.reg(0) == 0x00FE && rsp.reg(1) == 0x0ACD && rsp.reg(5) == 0x00FF);
		assert(@catch(pdu::decode_response(&r, support::hx("17 0A 00 FE 0A CD 00 01 00 03 00 0D"))) == modbus::BAD_BYTE_COUNT);
	};
}

fn void test_encode_write_responses() @test
{
	@pool()
	{
		char[260] out;
		Response r = { .fc = 0x0F, .addr = 19, .qty = 10 };
		usz n = pdu::encode_response(&r, &out)!!;
		support::assert_bytes(out[:n], "0F 00 13 00 0A", "V14");
		r = { .fc = 0x10, .addr = 1, .qty = 2 };
		n = pdu::encode_response(&r, &out)!!;
		support::assert_bytes(out[:n], "10 00 01 00 02", "V16");
		r = { .fc = 0x16, .addr = 4, .and_mask = 0xF2, .or_mask = 0x25 };
		n = pdu::encode_response(&r, &out)!!;
		support::assert_bytes(out[:n], "16 00 04 00 F2 00 25", "V18");
		r = { .fc = 0x17, .data = support::hx("00 FE 0A CD 00 01 00 03 00 0D 00 FF") };
		n = pdu::encode_response(&r, &out)!!;
		support::assert_bytes(out[:n], "17 0C 00 FE 0A CD 00 01 00 03 00 0D 00 FF", "V20");
		r = { .fc = 0x10, .is_exception = true, .exception = ExceptionCode.ILLEGAL_DATA_VALUE };
		n = pdu::encode_response(&r, &out)!!;
		support::assert_bytes(out[:n], "90 03");
	};
}

// ---- request limits: L11 to L22 ----

fn void test_fc15_limits() @test
{
	@pool()
	{
		assert(dec_fault(support::hx("0F 00 00 00 00 00")) == modbus::BAD_QUANTITY);               // L11
		assert(dec_fault(support::padded("0F 00 00 07 B1 F7", 247)) == modbus::BAD_QUANTITY);               // L12
		assert(dec_fault(support::hx("0F 00 00 00 0A 01 FF")) == modbus::BAD_BYTE_COUNT);          // L13
		assert(dec_fault(support::hx("0F 00 00 00 0A 03 FF FF FF")) == modbus::BAD_BYTE_COUNT);    // L14
		assert(pdu::decode_request(support::padded("0F 00 00 07 B0 F6", 246))!!.qty == 1968);               // largest legal
		assert(dec_fault(support::padded("0F FF FF 00 02 01", 1)) == modbus::BAD_ADDRESS_RANGE);
		// byte count and quantity agree but the PDU is cut / has an extra byte
		assert(dec_fault(support::hx("0F 00 00 00 0A 02 FF")) == modbus::TRUNCATED);
		assert(dec_fault(support::hx("0F 00 00 00 0A 02 FF FF 00")) == modbus::BAD_LENGTH);
	};
}

fn void test_fc16_limits() @test
{
	@pool()
	{
		assert(dec_fault(support::hx("10 00 00 00 00 00")) == modbus::BAD_QUANTITY);               // L15
		// L16: 124 registers need a 254-byte PDU, longer than the 253-byte limit: rejected for its length (answer 03)
		assert(dec_fault(support::padded("10 00 00 00 7C F8", 248)) == modbus::BAD_LENGTH);
		assert(pdu::fault_to_exception(modbus::BAD_LENGTH) == ExceptionCode.ILLEGAL_DATA_VALUE);
		assert(dec_fault(support::hx("10 00 00 00 7C 04 00 01 00 02")) == modbus::BAD_QUANTITY);
		assert(dec_fault(support::hx("10 00 00 00 02 03 00 01 00")) == modbus::BAD_BYTE_COUNT);    // L17
		assert(dec_fault(support::hx("10 00 00 00 02 04 00 01")) == modbus::TRUNCATED);            // L18
		assert(dec_fault(support::hx("10 00 00 00 02 04 00 01 00 02 00")) == modbus::BAD_LENGTH);  // L19
		assert(pdu::decode_request(support::padded("10 00 00 00 7B F6", 246))!!.qty == 123);
		assert(dec_fault(support::hx("10 FF FF 00 02 04 00 01 00 02")) == modbus::BAD_ADDRESS_RANGE);
		assert(pdu::decode_request(support::hx("10 FF FE 00 02 04 00 01 00 02"))!!.addr == 0xFFFE);
		assert(dec_fault(support::hx("10 00")) == modbus::SHORT_FRAME);
	};
}

fn void test_fc23_limits() @test
{
	@pool()
	{
		assert(dec_fault(support::hx("17 00 00 00 7E 00 00 00 01 02 00 01")) == modbus::BAD_QUANTITY);   // L20
		// L21: write quantity 122 needs a 254-byte PDU: rejected for its length (answer 03)
		assert(dec_fault(support::padded("17 00 00 00 01 00 00 00 7A F4", 244)) == modbus::BAD_LENGTH);
		assert(dec_fault(support::hx("17 00 00 00 01 00 00 00 7A 02 00 01")) == modbus::BAD_QUANTITY);
		assert(dec_fault(support::hx("17 00 00 00 01 00 00 00 01 04 00 01")) == modbus::TRUNCATED);      // L22 (byte count 4, 2 bytes)
		assert(dec_fault(support::hx("17 00 00 00 01 00 00 00 01 04 00 01 00 02")) == modbus::BAD_BYTE_COUNT);
		assert(dec_fault(support::hx("17 00 00 00 00 00 00 00 01 02 00 01")) == modbus::BAD_QUANTITY);   // read qty 0
		assert(dec_fault(support::hx("17 00 00 00 01 00 00 00 00 00")) == modbus::BAD_QUANTITY);         // write qty 0
		assert(pdu::decode_request(support::padded("17 00 00 00 7D 00 00 00 79 F2", 242))!!.write_qty == 121);
		assert(dec_fault(support::hx("17 FF FF 00 02 00 00 00 01 02 00 01")) == modbus::BAD_ADDRESS_RANGE);
		assert(dec_fault(support::hx("17 00 00 00 01 FF FF 00 02 04 00 01 00 02")) == modbus::BAD_ADDRESS_RANGE);
		assert(dec_fault(support::hx("17 00 00 00 01 00 00 00 01")) == modbus::SHORT_FRAME);
	};
}

fn void test_fc22_lengths() @test
{
	@pool()
	{
		assert(dec_fault(support::hx("16 00 04 00 F2 00")) == modbus::SHORT_FRAME);
		assert(dec_fault(support::hx("16 00 04 00 F2 00 25 00")) == modbus::BAD_LENGTH);
	};
}
