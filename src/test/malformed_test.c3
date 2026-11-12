module modbus::malformed_test;

import std::core::mem;
import modbus;
import modbus::pdu;
import modbus::support;

// Request PDUs of every supported function (spec examples and hand-made ones).
const String[] REQUESTS = {
	"01 00 13 00 13", "02 00 C4 00 16", "03 00 6B 00 03", "04 00 08 00 01",
	"05 00 AC FF 00", "06 00 01 00 03",
	"0F 00 13 00 0A 02 CD 01", "10 00 01 00 02 04 00 0A 01 02",
	"16 00 04 00 F2 00 25",
	"17 00 03 00 06 00 0E 00 03 06 12 34 56 78 9A BC",
	"08 00 00 A5 37", "11", "2B 0E 01 00", "2B 0E 04 05",
};

// Matching responses, same order as REQUESTS.
const String[] RESPONSES = {
	"01 03 CD 6B 05", "02 03 AC DB 35", "03 06 02 2B 00 00 00 64", "04 02 00 0A",
	"05 00 AC FF 00", "06 00 01 00 03",
	"0F 00 13 00 0A", "10 00 01 00 02",
	"16 00 04 00 F2 00 25",
	"17 0C 00 FE 0A CD 00 01 00 03 00 0D 00 FF",
	"08 00 00 A5 37", "11 04 01 FF 41 42",
	"2B 0E 01 01 00 00 03 00 03 41 42 43 01 02 58 59 02 03 31 2E 30",
	"2B 0E 04 81 00 00 01 05 02 4D 31",
};

fn void test_every_request_truncation_faults() @test
{
	@pool()
	{
		foreach (m : REQUESTS)
		{
			char[] full = support::hx(m);
			assert(@ok(pdu::decode_request(full)), "full request %s", m);
			for (usz cut = 0; cut < full.len; cut++)
			{
				assert(!@ok(pdu::decode_request(full[:cut])), "request %s cut to %d bytes", m, cut);
			}
		}
	};
}

fn void test_every_response_truncation_faults() @test
{
	@pool()
	{
		assert(REQUESTS.len == RESPONSES.len);
		foreach (i, m : RESPONSES)
		{
			Request rq = pdu::decode_request(support::hx(REQUESTS[i]))!!;
			char[] full = support::hx(m);
			assert(@ok(pdu::decode_response(&rq, full)), "full response %s", m);
			for (usz cut = 0; cut < full.len; cut++)
			{
				assert(!@ok(pdu::decode_response(&rq, full[:cut])), "response %s cut to %d bytes", m, cut);
			}
		}
	};
}

fn void test_every_request_with_extra_byte_faults() @test
{
	@pool()
	{
		foreach (m : REQUESTS)
		{
			char[] full = support::hx(m);
			char[] longer = mem::temp_array(char, (sz)(full.len + 1));
			mem::copy(longer.ptr, full.ptr, (sz)full.len);
			assert(!@ok(pdu::decode_request(longer)), "request %s plus one byte", m);
		}
	};
}

fn void test_every_response_with_extra_byte_faults() @test
{
	@pool()
	{
		foreach (i, m : RESPONSES)
		{
			Request rq = pdu::decode_request(support::hx(REQUESTS[i]))!!;
			char[] full = support::hx(m);
			char[] longer = mem::temp_array(char, (sz)(full.len + 1));
			mem::copy(longer.ptr, full.ptr, (sz)full.len);
			assert(!@ok(pdu::decode_response(&rq, longer)), "response %s plus one byte", m);
		}
	};
}

fn void test_byte_count_off_by_one() @test
{
	@pool()
	{
		// FC 15, 16 and 23 carry the byte count at offsets 5, 5 and 9
		String[] msgs = { "0F 00 13 00 0A 02 CD 01", "10 00 01 00 02 04 00 0A 01 02", "17 00 03 00 06 00 0E 00 03 06 12 34 56 78 9A BC" };
		usz[] at = { 5, 5, 9 };
		foreach (i, m : msgs)
		{
			char[] a = support::hx(m);
			assert(@ok(pdu::decode_request(a)));
			a[at[i]] += 1;
			assert(!@ok(pdu::decode_request(a)), "byte count + 1 in %s", m);
			a[at[i]] -= 2;
			assert(!@ok(pdu::decode_request(a)), "byte count - 1 in %s", m);
		}
	};
}

fn void test_quantity_one_over_each_limit() @test
{
	@pool()
	{
		String[] over = {
			"01 00 00 07 D1",                                    // FC 1: 2001
			"02 00 00 07 D1",                                    // FC 2: 2001
			"03 00 00 00 7E",                                    // FC 3: 126
			"04 00 00 00 7E",                                    // FC 4: 126
			"0F 00 00 07 B1 02 00 00",                           // FC 15: 1969
			"10 00 00 00 7C 02 00 00",                           // FC 16: 124
			"17 00 00 00 7E 00 00 00 01 02 00 00",               // FC 23 read: 126
			"17 00 00 00 01 00 00 00 7A 02 00 00",               // FC 23 write: 122
		};
		foreach (m : over)
		{
			fault f = @catch(pdu::decode_request(support::hx(m)));
			assert(f == modbus::BAD_QUANTITY, "quantity limit in %s", m);
			assert(pdu::fault_to_exception(f) == ExceptionCode.ILLEGAL_DATA_VALUE);
		}
		String[] zero = {
			"01 00 00 00 00", "02 00 00 00 00", "03 00 00 00 00", "04 00 00 00 00",
			"0F 00 00 00 00 00", "10 00 00 00 00 00",
		};
		foreach (m : zero)
		{
			assert(@catch(pdu::decode_request(support::hx(m))) == modbus::BAD_QUANTITY, "zero quantity in %s", m);
		}
	};
}

fn void test_unknown_and_reserved_function_codes() @test
{
	@pool()
	{
		assert(@catch(pdu::decode_request(support::hx("41 00 00"))) == modbus::UNSUPPORTED_FUNCTION);
		assert(@catch(pdu::decode_request(support::hx("07"))) == modbus::UNSUPPORTED_FUNCTION);
		assert(@catch(pdu::decode_request(support::hx("14 00"))) == modbus::UNSUPPORTED_FUNCTION);
		assert(@catch(pdu::decode_request(support::hx("7F"))) == modbus::UNSUPPORTED_FUNCTION);
		assert(@catch(pdu::decode_request(support::hx("FF 00"))) == modbus::UNSUPPORTED_FUNCTION);
		Request rq = pdu::read_request(Fc.READ_COILS, 0, 1);
		assert(@catch(pdu::decode_response(&rq, support::hx("83"))) == modbus::SHORT_FRAME);
		assert(@catch(pdu::decode_response(&rq, support::hx("81"))) == modbus::SHORT_FRAME);
	};
}

fn void test_pdu_of_254_bytes() @test
{
	char[254] big;
	char[7] fcs = { 1, 3, 0x0F, 0x10, 0x17, 8, 0x2B };
	foreach (fc : fcs)
	{
		big[0] = (char)fc;
		assert(@catch(pdu::decode_request(&big)) == modbus::BAD_LENGTH, "request fc %d", fc);
	}
	Request rq = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 1);
	big[0] = 3;
	assert(@catch(pdu::decode_response(&rq, &big)) == modbus::BAD_LENGTH);
	char[253] ok;
	ok[0] = 8;                                   // FC 8 with 250 data bytes is the longest legal PDU
	assert(pdu::decode_request(&ok)!!.data.len == 250);
}

// ---- random round trip ----

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

fn bool same(Request* a, Request* b)
{
	return a.fc == b.fc && a.sub == b.sub && a.addr == b.addr && a.qty == b.qty && a.value == b.value
		&& a.and_mask == b.and_mask && a.or_mask == b.or_mask && a.write_addr == b.write_addr && a.write_qty == b.write_qty
		&& a.read_dev_code == b.read_dev_code && a.object_id == b.object_id && a.data == b.data;
}

fn void test_random_requests_roundtrip() @test
{
	Rng rng = { .state = 20260101 };
	char[300] scratch;
	char[300] out;
	bool[1968] bits;
	ushort[123] regs;
	for (int round = 0; round < 1000; round++)
	{
		Request r;
		switch (rng.below(12))
		{
			case 0:
				ushort qty = (ushort)(1 + rng.below(2000));
				r = pdu::read_request(rng.below(2) == 0 ? Fc.READ_COILS : Fc.READ_DISCRETE_INPUTS, (ushort)rng.below(0x10000 - qty + 1), qty);
			case 1:
				ushort qty = (ushort)(1 + rng.below(125));
				r = pdu::read_request(rng.below(2) == 0 ? Fc.READ_HOLDING_REGISTERS : Fc.READ_INPUT_REGISTERS, (ushort)rng.below(0x10000 - qty + 1), qty);
			case 2:
				r = pdu::write_single_coil((ushort)rng.below(0x10000), rng.below(2) == 0);
			case 3:
				r = pdu::write_single_register((ushort)rng.below(0x10000), (ushort)rng.below(0x10000));
			case 4:
				uint n = 1 + rng.below(1968);
				for (uint i = 0; i < n; i++) bits[i] = rng.below(2) == 0;
				r = pdu::write_multiple_coils((ushort)rng.below(0x10000 - n + 1), bits[:n], &scratch)!!;
			case 5:
				uint n = 1 + rng.below(123);
				for (uint i = 0; i < n; i++) regs[i] = (ushort)rng.below(0x10000);
				r = pdu::write_multiple_registers((ushort)rng.below(0x10000 - n + 1), regs[:n], &scratch)!!;
			case 6:
				r = pdu::mask_write_register((ushort)rng.below(0x10000), (ushort)rng.below(0x10000), (ushort)rng.below(0x10000));
			case 7:
				uint n = 1 + rng.below(121);
				for (uint i = 0; i < n; i++) regs[i] = (ushort)rng.below(0x10000);
				ushort rq = (ushort)(1 + rng.below(125));
				r = pdu::read_write_registers((ushort)rng.below(0x10000 - rq + 1), rq, (ushort)rng.below(0x10000 - n + 1), regs[:n], &scratch)!!;
			case 8:
				uint n = 2 * (1 + rng.below(125));
				for (uint i = 0; i < n; i++) scratch[i] = (char)rng.below(256);
				r = { .fc = (char)Fc.DIAGNOSTICS, .sub = (ushort)rng.below(0x10000), .data = scratch[:n] };
			case 9:
				r = { .fc = (char)Fc.REPORT_SERVER_ID };
			default:
				r = pdu::read_device_id((char)(1 + rng.below(4)), (char)rng.below(256));
		}
		usz n = pdu::encode_request(&r, &out)!!;
		assert(n <= modbus::MAX_PDU, "round %d length %d", round, n);
		Request d = pdu::decode_request(out[:n])!!;
		assert(same(&r, &d), "round %d fc %02x", round, r.fc);
		// and every shorter prefix is rejected
		assert(!@ok(pdu::decode_request(out[:n - 1])), "round %d prefix", round);
	}
}
