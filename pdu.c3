module modbus::pdu;

import std::core::mem;
import modbus;

// Zero-allocation PDU codec (Modbus Application Protocol 4.1, 6.x, 7). Requests and responses carry
// wire-format bytes in `data` (borrowed: valid as long as the buffer they were decoded from / built over).

struct Request
{
	char fc;
	ushort sub;          // FC 8 sub-function; FC 43 MEI type (low byte)
	ushort addr;         // starting address / reference address
	ushort qty;          // quantity of coils/registers
	ushort value;        // FC 5 raw value (0xFF00/0x0000), FC 6 value
	ushort and_mask;     // FC 22
	ushort or_mask;      // FC 22
	ushort write_addr;   // FC 23
	ushort write_qty;    // FC 23
	char read_dev_code;  // FC 43/14: 1 basic, 2 regular, 3 extended, 4 individual
	char object_id;      // FC 43/14
	char[] data;         // write payload (packed coil bits LSB first, or registers big-endian)
}

struct Response
{
	char fc;             // function code without the 0x80 bit
	bool is_exception;   // true: exception response, other fields unused (a peer can send code 0)
	ExceptionCode exception;  // raw code byte, any value 0..255 passes through (valid only if is_exception)
	ushort sub;          // FC 8 sub-function echo; FC 43 MEI type
	ushort addr;         // echoes (FC 5, 6, 15, 16, 22)
	ushort qty;          // quantity requested (reads); coil accessors ignore bits >= qty
	ushort value;
	ushort and_mask;
	ushort or_mask;
	char read_dev_code;  // FC 43/14: echoed Read Device ID code
	char conformity;     // FC 43/14
	bool more_follows;   // FC 43/14
	char next_object_id; // FC 43/14
	char object_count;   // FC 43/14
	char[] data;         // coil bytes / register bytes / device-id object bytes / server id
}

// ---- helpers ----

fn ushort get16(char[] b, usz at) @private
{
	return (ushort)(((ushort)b[at] << 8) | b[at + 1]);
}

fn void put16(char[] b, usz at, ushort v) @private
{
	b[at] = (char)(v >> 8);
	b[at + 1] = (char)(v & 0xFF);
}

fn bool is_bit_read(Fc fc) @private
{
	return fc == Fc.READ_COILS || fc == Fc.READ_DISCRETE_INPUTS;
}

fn bool is_read_fc(Fc fc) @private
{
	return fc == Fc.READ_COILS || fc == Fc.READ_DISCRETE_INPUTS || fc == Fc.READ_HOLDING_REGISTERS || fc == Fc.READ_INPUT_REGISTERS;
}

// Largest quantity of the read functions (MAP 6.1 to 6.4).
fn ushort max_read_qty(Fc fc) @private
{
	return is_bit_read(fc) ? modbus::MAX_READ_BITS : modbus::MAX_READ_REGS;
}

fn bool range_ok(ushort addr, usz qty) @private
{
	return (usz)addr + qty <= 0x10000;
}

// ---- builders ----

fn Request read_request(Fc fc, ushort addr, ushort qty)
{
	return { .fc = (char)fc, .addr = addr, .qty = qty };
}

fn Request write_single_coil(ushort addr, bool on)
{
	return { .fc = (char)Fc.WRITE_SINGLE_COIL, .addr = addr, .value = on ? 0xFF00 : 0x0000 };
}

fn Request write_single_register(ushort addr, ushort value)
{
	return { .fc = (char)Fc.WRITE_SINGLE_REGISTER, .addr = addr, .value = value };
}

fn Request mask_write_register(ushort addr, ushort and_mask, ushort or_mask)
{
	return { .fc = (char)Fc.MASK_WRITE_REGISTER, .addr = addr, .and_mask = and_mask, .or_mask = or_mask };
}

fn Request read_device_id(char code, char object_id)
{
	return { .fc = (char)Fc.ENCAPSULATED_INTERFACE, .sub = modbus::MEI_READ_DEVICE_ID, .read_dev_code = code, .object_id = object_id };
}

// Packs bits LSB first into scratch (the payload of FC 15). BAD_QUANTITY for 0 or more than 1968 bits.
fn Request? write_multiple_coils(ushort addr, bool[] bits, char[] scratch)
{
	if (bits.len < 1 || bits.len > modbus::MAX_WRITE_BITS) return modbus::BAD_QUANTITY~;
	usz bytes = (bits.len + 7) / 8;
	if (scratch.len < bytes) return modbus::BUFFER_TOO_SMALL~;
	for (usz i = 0; i < bytes; i++) scratch[i] = 0;
	foreach (i, b : bits)
	{
		if (b) scratch[i / 8] |= (char)(1 << (i % 8));
	}
	return { .fc = (char)Fc.WRITE_MULTIPLE_COILS, .addr = addr, .qty = (ushort)bits.len, .data = scratch[:bytes] };
}

// Big-endian register payload of FC 16 in scratch. BAD_QUANTITY for 0 or more than 123 registers.
fn Request? write_multiple_registers(ushort addr, ushort[] regs, char[] scratch)
{
	if (regs.len < 1 || regs.len > modbus::MAX_WRITE_REGS) return modbus::BAD_QUANTITY~;
	if (scratch.len < regs.len * 2) return modbus::BUFFER_TOO_SMALL~;
	foreach (i, r : regs) put16(scratch, (usz)i * 2, r);
	return { .fc = (char)Fc.WRITE_MULTIPLE_REGISTERS, .addr = addr, .qty = (ushort)regs.len, .data = scratch[:regs.len * 2] };
}

// FC 23: read read_qty registers at read_addr, after writing regs at write_addr.
fn Request? read_write_registers(ushort read_addr, ushort read_qty, ushort write_addr, ushort[] regs, char[] scratch)
{
	if (read_qty < 1 || read_qty > modbus::MAX_RW_READ_REGS) return modbus::BAD_QUANTITY~;
	if (regs.len < 1 || regs.len > modbus::MAX_RW_WRITE_REGS) return modbus::BAD_QUANTITY~;
	if (scratch.len < regs.len * 2) return modbus::BUFFER_TOO_SMALL~;
	foreach (i, r : regs) put16(scratch, (usz)i * 2, r);
	return {
		.fc = (char)Fc.READ_WRITE_MULTIPLE_REGISTERS,
		.addr = read_addr,
		.qty = read_qty,
		.write_addr = write_addr,
		.write_qty = (ushort)regs.len,
		.data = scratch[:regs.len * 2],
	};
}

// ---- limits of one request ----

// Order: quantities, then byte counts / payload sizes, then address ranges, then values (MAP 7: 03 before 02).
fn void? check_request(Request* req) @private
{
	Fc fc = (Fc)req.fc;
	switch (fc)
	{
		case READ_COILS:
		case READ_DISCRETE_INPUTS:
		case READ_HOLDING_REGISTERS:
		case READ_INPUT_REGISTERS:
			if (req.qty < 1 || req.qty > max_read_qty(fc)) return modbus::BAD_QUANTITY~;
			if (!range_ok(req.addr, req.qty)) return modbus::BAD_ADDRESS_RANGE~;
		case WRITE_SINGLE_COIL:
			if (req.value != 0x0000 && req.value != 0xFF00) return modbus::BAD_VALUE~;
		case WRITE_SINGLE_REGISTER:
		case MASK_WRITE_REGISTER:
			return;
		case WRITE_MULTIPLE_COILS:
			if (req.qty < 1 || req.qty > modbus::MAX_WRITE_BITS) return modbus::BAD_QUANTITY~;
			if (req.data.len != ((usz)req.qty + 7) / 8) return modbus::BAD_BYTE_COUNT~;
			if (!range_ok(req.addr, req.qty)) return modbus::BAD_ADDRESS_RANGE~;
		case WRITE_MULTIPLE_REGISTERS:
			if (req.qty < 1 || req.qty > modbus::MAX_WRITE_REGS) return modbus::BAD_QUANTITY~;
			if (req.data.len != (usz)req.qty * 2) return modbus::BAD_BYTE_COUNT~;
			if (!range_ok(req.addr, req.qty)) return modbus::BAD_ADDRESS_RANGE~;
		case READ_WRITE_MULTIPLE_REGISTERS:
			if (req.qty < 1 || req.qty > modbus::MAX_RW_READ_REGS) return modbus::BAD_QUANTITY~;
			if (req.write_qty < 1 || req.write_qty > modbus::MAX_RW_WRITE_REGS) return modbus::BAD_QUANTITY~;
			if (req.data.len != (usz)req.write_qty * 2) return modbus::BAD_BYTE_COUNT~;
			if (!range_ok(req.addr, req.qty) || !range_ok(req.write_addr, req.write_qty)) return modbus::BAD_ADDRESS_RANGE~;
		case DIAGNOSTICS:
			// data is N x 2 bytes, at least 2 and at most 250 (the PDU is at most 253 bytes)
			if (req.data.len < 2 || req.data.len > 250 || req.data.len % 2 != 0) return modbus::BAD_LENGTH~;
		case REPORT_SERVER_ID:
			return;
		case ENCAPSULATED_INTERFACE:
			if (req.sub != modbus::MEI_READ_DEVICE_ID) return modbus::UNSUPPORTED_FUNCTION~;
			if (req.read_dev_code < 1 || req.read_dev_code > 4) return modbus::BAD_VALUE~;
		default:
			return modbus::UNSUPPORTED_FUNCTION~;
	}
}

// ---- codec ----

// Returns the PDU length. Applies the same limits as decode_request.
fn usz? encode_request(Request* req, char[] out)
{
	check_request(req)!;
	usz total;
	Fc fc = (Fc)req.fc;
	switch (fc)
	{
		case READ_COILS:
		case READ_DISCRETE_INPUTS:
		case READ_HOLDING_REGISTERS:
		case READ_INPUT_REGISTERS:
			total = 5;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			put16(out, 1, req.addr);
			put16(out, 3, req.qty);
		case WRITE_SINGLE_COIL:
		case WRITE_SINGLE_REGISTER:
			total = 5;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			put16(out, 1, req.addr);
			put16(out, 3, req.value);
		case MASK_WRITE_REGISTER:
			total = 7;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			put16(out, 1, req.addr);
			put16(out, 3, req.and_mask);
			put16(out, 5, req.or_mask);
		case WRITE_MULTIPLE_COILS:
		case WRITE_MULTIPLE_REGISTERS:
			total = 6 + req.data.len;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			put16(out, 1, req.addr);
			put16(out, 3, req.qty);
			out[5] = (char)req.data.len;
			mem::copy(&out[6], req.data.ptr, (sz)req.data.len);
		case READ_WRITE_MULTIPLE_REGISTERS:
			total = 10 + req.data.len;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			put16(out, 1, req.addr);
			put16(out, 3, req.qty);
			put16(out, 5, req.write_addr);
			put16(out, 7, req.write_qty);
			out[9] = (char)req.data.len;
			mem::copy(&out[10], req.data.ptr, (sz)req.data.len);
		case DIAGNOSTICS:
			total = 3 + req.data.len;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			put16(out, 1, req.sub);
			mem::copy(&out[3], req.data.ptr, (sz)req.data.len);
		case REPORT_SERVER_ID:
			total = 1;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
		case ENCAPSULATED_INTERFACE:
			total = 4;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			out[1] = (char)req.sub;
			out[2] = req.read_dev_code;
			out[3] = req.object_id;
		default:
			return modbus::UNSUPPORTED_FUNCTION~;
	}
	out[0] = req.fc;
	return total;
}

// Server side. On a fault no Request is returned: the server answers from pdu[0] (the function code).
// Order of checks: length, function supported, then the limits of check_request.
fn Request? decode_request(char[] pdu)
{
	if (pdu.len == 0) return modbus::SHORT_FRAME~;
	if (pdu.len > modbus::MAX_PDU) return modbus::BAD_LENGTH~;
	Fc fc = (Fc)pdu[0];
	Request req = { .fc = pdu[0] };
	switch (fc)
	{
		case READ_COILS:
		case READ_DISCRETE_INPUTS:
		case READ_HOLDING_REGISTERS:
		case READ_INPUT_REGISTERS:
			if (pdu.len < 5) return modbus::SHORT_FRAME~;
			if (pdu.len > 5) return modbus::BAD_LENGTH~;
			req.addr = get16(pdu, 1);
			req.qty = get16(pdu, 3);
		case WRITE_SINGLE_COIL:
		case WRITE_SINGLE_REGISTER:
			if (pdu.len < 5) return modbus::SHORT_FRAME~;
			if (pdu.len > 5) return modbus::BAD_LENGTH~;
			req.addr = get16(pdu, 1);
			req.value = get16(pdu, 3);
		case MASK_WRITE_REGISTER:
			if (pdu.len < 7) return modbus::SHORT_FRAME~;
			if (pdu.len > 7) return modbus::BAD_LENGTH~;
			req.addr = get16(pdu, 1);
			req.and_mask = get16(pdu, 3);
			req.or_mask = get16(pdu, 5);
		case WRITE_MULTIPLE_COILS:
		case WRITE_MULTIPLE_REGISTERS:
			if (pdu.len < 6) return modbus::SHORT_FRAME~;
			usz count = pdu[5];
			if (pdu.len < 6 + count) return modbus::TRUNCATED~;
			if (pdu.len > 6 + count) return modbus::BAD_LENGTH~;
			req.addr = get16(pdu, 1);
			req.qty = get16(pdu, 3);
			req.data = pdu[6:count];
		case READ_WRITE_MULTIPLE_REGISTERS:
			if (pdu.len < 10) return modbus::SHORT_FRAME~;
			usz count = pdu[9];
			if (pdu.len < 10 + count) return modbus::TRUNCATED~;
			if (pdu.len > 10 + count) return modbus::BAD_LENGTH~;
			req.addr = get16(pdu, 1);
			req.qty = get16(pdu, 3);
			req.write_addr = get16(pdu, 5);
			req.write_qty = get16(pdu, 7);
			req.data = pdu[10:count];
		case DIAGNOSTICS:
			if (pdu.len < 5) return modbus::SHORT_FRAME~;
			req.sub = get16(pdu, 1);
			req.data = pdu[3..];
		case REPORT_SERVER_ID:
			if (pdu.len > 1) return modbus::BAD_LENGTH~;
		case ENCAPSULATED_INTERFACE:
			if (pdu.len < 2) return modbus::SHORT_FRAME~;
			if (pdu[1] != modbus::MEI_READ_DEVICE_ID) return modbus::UNSUPPORTED_FUNCTION~;
			if (pdu.len < 4) return modbus::SHORT_FRAME~;
			if (pdu.len > 4) return modbus::BAD_LENGTH~;
			req.sub = pdu[1];
			req.read_dev_code = pdu[2];
			req.object_id = pdu[3];
		default:
			return modbus::UNSUPPORTED_FUNCTION~;
	}
	check_request(&req)!;
	return req;
}

// Checks `count` objects (id, length, value) in data and that nothing follows them.
fn void? check_objects(char[] data, usz count) @private
{
	usz at = 0;
	for (usz i = 0; i < count; i++)
	{
		if (data.len - at < 2) return modbus::TRUNCATED~;
		usz len = data[at + 1];
		if (data.len - at < 2 + len) return modbus::TRUNCATED~;
		at += 2 + len;
	}
	if (at != data.len) return modbus::BAD_LENGTH~;
}

// Server side. Exception responses (is_exception) are encoded as fc | 0x80, code.
// Read responses: data is the packed coils / register bytes, byte count = data.len.
fn usz? encode_response(Response* rsp, char[] out)
{
	if (rsp.is_exception)
	{
		if (out.len < 2) return modbus::BUFFER_TOO_SMALL~;
		return encode_exception(rsp.fc, rsp.exception, out);
	}
	Fc fc = (Fc)rsp.fc;
	usz total;
	switch (fc)
	{
		case READ_COILS:
		case READ_DISCRETE_INPUTS:
		case READ_HOLDING_REGISTERS:
		case READ_INPUT_REGISTERS:
		case READ_WRITE_MULTIPLE_REGISTERS:
			bool regs = fc != Fc.READ_COILS && fc != Fc.READ_DISCRETE_INPUTS;
			if (rsp.data.len < 1 || rsp.data.len > 250 || (regs && rsp.data.len % 2 != 0)) return modbus::BAD_BYTE_COUNT~;
			total = 2 + rsp.data.len;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			out[1] = (char)rsp.data.len;
			mem::copy(&out[2], rsp.data.ptr, (sz)rsp.data.len);
		case WRITE_SINGLE_COIL:
		case WRITE_SINGLE_REGISTER:
		case WRITE_MULTIPLE_COILS:
		case WRITE_MULTIPLE_REGISTERS:
			if (fc == Fc.WRITE_SINGLE_COIL && rsp.value != 0x0000 && rsp.value != 0xFF00) return modbus::BAD_VALUE~;
			total = 5;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			put16(out, 1, rsp.addr);
			put16(out, 3, (fc == Fc.WRITE_MULTIPLE_COILS || fc == Fc.WRITE_MULTIPLE_REGISTERS) ? rsp.qty : rsp.value);
		case MASK_WRITE_REGISTER:
			total = 7;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			put16(out, 1, rsp.addr);
			put16(out, 3, rsp.and_mask);
			put16(out, 5, rsp.or_mask);
		case DIAGNOSTICS:
			if (rsp.data.len < 2 || rsp.data.len > 250 || rsp.data.len % 2 != 0) return modbus::BAD_LENGTH~;
			total = 3 + rsp.data.len;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			put16(out, 1, rsp.sub);
			mem::copy(&out[3], rsp.data.ptr, (sz)rsp.data.len);
		case REPORT_SERVER_ID:
			if (rsp.data.len > 250) return modbus::BAD_BYTE_COUNT~;
			total = 2 + rsp.data.len;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			out[1] = (char)rsp.data.len;
			mem::copy(&out[2], rsp.data.ptr, (sz)rsp.data.len);
		case ENCAPSULATED_INTERFACE:
			check_objects(rsp.data, rsp.object_count)!;
			total = 7 + rsp.data.len;
			if (total > modbus::MAX_PDU) return modbus::BAD_LENGTH~;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			out[1] = modbus::MEI_READ_DEVICE_ID;
			out[2] = rsp.read_dev_code;
			out[3] = rsp.conformity;
			out[4] = rsp.more_follows ? 0xFF : 0x00;
			out[5] = rsp.next_object_id;
			out[6] = rsp.object_count;
			mem::copy(&out[7], rsp.data.ptr, (sz)rsp.data.len);
		default:
			return modbus::UNSUPPORTED_FUNCTION~;
	}
	out[0] = rsp.fc;
	return total;
}

// Client side; checks the response against its request: function code, byte count, echoes, objects.
// A peer exception is data, not a fault: Response.is_exception with the raw code.
fn Response? decode_response(Request* req, char[] pdu)
{
	if (pdu.len == 0) return modbus::SHORT_FRAME~;
	if (pdu.len > modbus::MAX_PDU) return modbus::BAD_LENGTH~;
	Response rsp = { .fc = pdu[0] & 0x7F };
	if (modbus::is_exception_fc(pdu[0]))
	{
		if (pdu.len < 2) return modbus::SHORT_FRAME~;
		if (pdu.len > 2) return modbus::BAD_LENGTH~;
		if (rsp.fc != req.fc) return modbus::MISMATCH~;
		rsp.is_exception = true;
		rsp.exception = modbus::raw_exception(pdu[1]);
		return rsp;
	}
	if (pdu[0] != req.fc) return modbus::MISMATCH~;
	Fc fc = (Fc)pdu[0];
	switch (fc)
	{
		case READ_COILS:
		case READ_DISCRETE_INPUTS:
		case READ_HOLDING_REGISTERS:
		case READ_INPUT_REGISTERS:
		case READ_WRITE_MULTIPLE_REGISTERS:
			if (pdu.len < 2) return modbus::SHORT_FRAME~;
			usz want = is_bit_read(fc) ? ((usz)req.qty + 7) / 8 : (usz)req.qty * 2;
			usz count = pdu[1];
			if (count != want) return modbus::BAD_BYTE_COUNT~;
			if (pdu.len < 2 + count) return modbus::TRUNCATED~;
			if (pdu.len > 2 + count) return modbus::BAD_LENGTH~;
			rsp.qty = req.qty;
			rsp.data = pdu[2:count];
		case WRITE_SINGLE_COIL:
		case WRITE_SINGLE_REGISTER:
			if (pdu.len < 5) return modbus::SHORT_FRAME~;
			if (pdu.len > 5) return modbus::BAD_LENGTH~;
			rsp.addr = get16(pdu, 1);
			rsp.value = get16(pdu, 3);
			if (rsp.addr != req.addr || rsp.value != req.value) return modbus::MISMATCH~;
		case WRITE_MULTIPLE_COILS:
		case WRITE_MULTIPLE_REGISTERS:
			if (pdu.len < 5) return modbus::SHORT_FRAME~;
			if (pdu.len > 5) return modbus::BAD_LENGTH~;
			rsp.addr = get16(pdu, 1);
			rsp.qty = get16(pdu, 3);
			if (rsp.addr != req.addr || rsp.qty != req.qty) return modbus::MISMATCH~;
		case MASK_WRITE_REGISTER:
			if (pdu.len < 7) return modbus::SHORT_FRAME~;
			if (pdu.len > 7) return modbus::BAD_LENGTH~;
			rsp.addr = get16(pdu, 1);
			rsp.and_mask = get16(pdu, 3);
			rsp.or_mask = get16(pdu, 5);
			if (rsp.addr != req.addr || rsp.and_mask != req.and_mask || rsp.or_mask != req.or_mask) return modbus::MISMATCH~;
		case DIAGNOSTICS:
			if (pdu.len < 5) return modbus::SHORT_FRAME~;
			if (pdu.len % 2 != 1) return modbus::BAD_LENGTH~;
			rsp.sub = get16(pdu, 1);
			rsp.data = pdu[3..];
			if (rsp.sub != req.sub) return modbus::MISMATCH~;
			if (rsp.sub == 0 && rsp.data != req.data) return modbus::MISMATCH~;   // return query data echoes the request
		case REPORT_SERVER_ID:
			if (pdu.len < 2) return modbus::SHORT_FRAME~;
			usz count = pdu[1];
			if (pdu.len < 2 + count) return modbus::TRUNCATED~;
			if (pdu.len > 2 + count) return modbus::BAD_LENGTH~;
			rsp.data = pdu[2:count];
		case ENCAPSULATED_INTERFACE:
			if (pdu.len < 7) return modbus::SHORT_FRAME~;
			if (pdu[1] != modbus::MEI_READ_DEVICE_ID) return modbus::MISMATCH~;
			if (pdu[2] != req.read_dev_code) return modbus::MISMATCH~;
			if (pdu[4] != 0x00 && pdu[4] != 0xFF) return modbus::BAD_VALUE~;
			rsp.sub = pdu[1];
			rsp.read_dev_code = pdu[2];
			rsp.conformity = pdu[3];
			rsp.more_follows = pdu[4] == 0xFF;
			rsp.next_object_id = pdu[5];
			rsp.object_count = pdu[6];
			rsp.data = pdu[7..];
			check_objects(rsp.data, rsp.object_count)!;
		default:
			return modbus::UNSUPPORTED_FUNCTION~;
	}
	return rsp;
}

// fc | 0x80, code (MAP 7). Returns the length (2), or 0 when `out` is too small.
fn usz encode_exception(char fc, ExceptionCode code, char[] out)
{
	if (out.len < 2) return 0;
	out[0] = fc | 0x80;
	out[1] = (char)code;
	return 2;
}

// Maps a decode fault to the exception code the server sends (MAP 7): wrong sizes, quantities and values
// -> ILLEGAL_DATA_VALUE, unsupported function -> ILLEGAL_FUNCTION, bad address range -> ILLEGAL_DATA_ADDRESS.
fn ExceptionCode fault_to_exception(fault f)
{
	if (f == modbus::UNSUPPORTED_FUNCTION) return ExceptionCode.ILLEGAL_FUNCTION;
	if (f == modbus::BAD_ADDRESS_RANGE) return ExceptionCode.ILLEGAL_DATA_ADDRESS;
	if (f == modbus::BAD_QUANTITY || f == modbus::BAD_BYTE_COUNT || f == modbus::BAD_VALUE
		|| f == modbus::SHORT_FRAME || f == modbus::BAD_LENGTH || f == modbus::TRUNCATED)
	{
		return ExceptionCode.ILLEGAL_DATA_VALUE;
	}
	return ExceptionCode.SERVER_DEVICE_FAILURE;
}

// ---- accessors over Response.data (wire format) ----

// Register `index` (big-endian pair); 0 when out of range.
fn ushort Response.reg(&self, usz index)
{
	if (index >= self.data.len / 2) return 0;
	return get16(self.data, index * 2);
}

// Coil `index` (bit 0 of byte 0 is the first coil); false for bits at or beyond qty (padding) or the data.
fn bool Response.coil(&self, usz index)
{
	if (index >= self.qty || index / 8 >= self.data.len) return false;
	return ((self.data[index / 8] >> (index % 8)) & 1) != 0;
}

fn usz Response.reg_count(&self)
{
	return self.data.len / 2;
}

// Copies all registers; SHORT_REGISTERS when `out` is shorter than reg_count().
fn void? Response.copy_regs(&self, ushort[] out)
{
	usz n = self.reg_count();
	if (out.len < n) return modbus::SHORT_REGISTERS~;
	for (usz i = 0; i < n; i++) out[i] = get16(self.data, i * 2);
}

// Copies the first qty coils; SHORT_REGISTERS when `out` is shorter than qty.
fn void? Response.copy_coils(&self, bool[] out)
{
	if (out.len < self.qty) return modbus::SHORT_REGISTERS~;
	for (usz i = 0; i < self.qty; i++) out[i] = self.coil(i);
}

// ---- FC 43/14 objects: iterate over Response.data (object id, length, value)* ----

struct DeviceObject
{
	char id;
	String value;        // borrowed
}

struct ObjectIter
{
	char[] rest;
}

fn ObjectIter objects(Response* rsp)
{
	return { .rest = rsp.data };
}

// true: *out holds the next object. false: no more objects. TRUNCATED when an object is cut short.
fn bool? ObjectIter.next(&self, DeviceObject* out)
{
	if (self.rest.len == 0) return false;
	if (self.rest.len < 2) return modbus::TRUNCATED~;
	usz len = self.rest[1];
	if (self.rest.len < 2 + len) return modbus::TRUNCATED~;
	out.id = self.rest[0];
	out.value = (String)self.rest[2:len];
	self.rest = self.rest[2 + len..];
	return true;
}
