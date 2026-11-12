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

// Largest quantity of the read functions (MAP 6.1 to 6.4).
fn ushort max_read_qty(Fc fc) @private
{
	return (fc == Fc.READ_COILS || fc == Fc.READ_DISCRETE_INPUTS) ? modbus::MAX_READ_BITS : modbus::MAX_READ_REGS;
}

fn bool is_read_fc(Fc fc) @private
{
	return fc == Fc.READ_COILS || fc == Fc.READ_DISCRETE_INPUTS || fc == Fc.READ_HOLDING_REGISTERS || fc == Fc.READ_INPUT_REGISTERS;
}

// Limits of one request. Order: quantity, then address range, then value (MAP 7: 03 before 02 for a bad quantity).
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
			if ((uint)req.addr + req.qty > 0x10000) return modbus::BAD_ADDRESS_RANGE~;
		case WRITE_SINGLE_COIL:
			if (req.value != 0x0000 && req.value != 0xFF00) return modbus::BAD_VALUE~;
		case WRITE_SINGLE_REGISTER:
			return;
		default:
			return modbus::UNSUPPORTED_FUNCTION~;
	}
}

// ---- codec ----

// Returns the PDU length. Applies the same limits as decode_request.
fn usz? encode_request(Request* req, char[] out)
{
	check_request(req)!;
	if (out.len < 5) return modbus::BUFFER_TOO_SMALL~;
	out[0] = req.fc;
	put16(out, 1, req.addr);
	put16(out, 3, is_read_fc((Fc)req.fc) ? req.qty : req.value);
	return 5;
}

// Server side. On a fault no Request is returned: the server answers from pdu[0] (the function code).
// Order of checks: length, function supported, quantity, address range.
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
		default:
			return modbus::UNSUPPORTED_FUNCTION~;
	}
	check_request(&req)!;
	return req;
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
	switch (fc)
	{
		case READ_COILS:
		case READ_DISCRETE_INPUTS:
		case READ_HOLDING_REGISTERS:
		case READ_INPUT_REGISTERS:
			bool regs = fc == Fc.READ_HOLDING_REGISTERS || fc == Fc.READ_INPUT_REGISTERS;
			if (rsp.data.len < 1 || rsp.data.len > 250 || (regs && rsp.data.len % 2 != 0)) return modbus::BAD_BYTE_COUNT~;
			usz total = 2 + rsp.data.len;
			if (out.len < total) return modbus::BUFFER_TOO_SMALL~;
			out[0] = rsp.fc;
			out[1] = (char)rsp.data.len;
			mem::copy(&out[2], rsp.data.ptr, (sz)rsp.data.len);
			return total;
		case WRITE_SINGLE_COIL:
		case WRITE_SINGLE_REGISTER:
			if (out.len < 5) return modbus::BUFFER_TOO_SMALL~;
			out[0] = rsp.fc;
			put16(out, 1, rsp.addr);
			put16(out, 3, rsp.value);
			return 5;
		default:
			return modbus::UNSUPPORTED_FUNCTION~;
	}
}

// Client side; checks the response against its request: function code, byte count, echoes.
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
			if (pdu.len < 2) return modbus::SHORT_FRAME~;
			bool bits = fc == Fc.READ_COILS || fc == Fc.READ_DISCRETE_INPUTS;
			usz want = bits ? ((usz)req.qty + 7) / 8 : (usz)req.qty * 2;
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
