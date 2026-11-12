module modbus::server;

import std::core::mem;
import std::core::mem::alloc;
import modbus;
import modbus::pdu;
import modbus::frame;

// Data model callbacks. Return ExceptionCode.NONE on success. Addresses are protocol addresses (0-based);
// the server has already checked quantity limits and addr + qty <= 0x10000.
interface DataModel
{
	// False: the model takes no writes at all; every write function is then answered with ILLEGAL_FUNCTION
	// before any range is looked at.
	fn bool writable(char unit);
	// Whole-range check, called before any write (no partial effect) and before a read.
	fn ExceptionCode check_range(char unit, Table table, ushort addr, ushort qty);
	fn ExceptionCode read_coils(char unit, ushort addr, bool[] out);
	fn ExceptionCode read_discrete_inputs(char unit, ushort addr, bool[] out);
	fn ExceptionCode read_holding(char unit, ushort addr, ushort[] out);
	fn ExceptionCode read_input(char unit, ushort addr, ushort[] out);
	fn ExceptionCode write_coils(char unit, ushort addr, bool[] values);
	fn ExceptionCode write_holding(char unit, ushort addr, ushort[] values);
}

struct ServerConfig
{
	bool accept_any_unit;       // else only the units listed in `units` (unit 0 is then never served)
	char[] units;
	// Lower limits per function; 0 = spec maximum (MAP 6.x). Larger requests answer ILLEGAL_DATA_VALUE.
	ushort max_read_bits;
	ushort max_read_regs;
	ushort max_write_bits;
	ushort max_write_regs;
	usz output_size;            // bytes of output buffer per connection; 0: 4 x 260
	// Device identification (FC 43/14): objects in ascending id order, values at most 244 bytes. Borrowed.
	pdu::DeviceObject[] device_objects;
	char conformity_level;      // sent as is: 0x01 basic, 0x02 regular, 0x03 extended, plus 0x80 when individual access is offered
	char[] server_id;           // FC 0x11 payload (id, run indicator, additional data); empty: ILLEGAL_FUNCTION
	bool allow_diagnostics;     // FC 8: sub-function 0x0000 (return query data) is answered; false: ILLEGAL_FUNCTION
}

const usz MAX_OBJECT_VALUE = 244;     // 253 - 7 header bytes - 2 object header bytes

// Checks what the server cannot answer correctly: objects out of order or with a value that cannot fit a PDU.
fn void? ServerConfig.check(&self)
{
	int last = -1;
	foreach (o : self.device_objects)
	{
		if (o.value.len > MAX_OBJECT_VALUE) return modbus::BAD_LENGTH~;
		if ((int)o.id <= last) return modbus::BAD_VALUE~;
		last = o.id;
	}
	if (self.server_id.len > 250) return modbus::BAD_LENGTH~;
}

// One per connection. Holds the framer and the pending output.
struct ServerConn
{
	ServerConfig* config;
	DataModel model;
	Allocator allocator;
	MbapFramer framer;
	char[] out;
	usz out_len;
	bool broken;
}

// BUFFER_TOO_SMALL when the output buffer cannot hold one ADU (it could never progress).
fn void? ServerConn.init(&self, ServerConfig* config, DataModel model, Allocator allocator)
{
	usz size = config.output_size == 0 ? 4 * modbus::MAX_TCP_ADU : config.output_size;
	if (size < modbus::MAX_TCP_ADU) return modbus::BUFFER_TOO_SMALL~;
	config.check()!;
	*self = {};
	self.config = config;
	self.model = model;
	self.allocator = allocator;
	self.out = alloc::new_array_try(allocator, char, (sz)size)!;
}

fn void ServerConn.free(&self)
{
	if (self.out.ptr) alloc::free(self.allocator, self.out.ptr);
	self.out = {};
	self.out_len = 0;
}

// Appends bytes to the framer (returns the bytes taken, less than data.len when the framer is full) and runs pump().
// A fault means: close the connection.
fn usz? ServerConn.feed(&self, char[] data)
{
	if (self.broken) return modbus::CLOSED~;
	usz taken = self.framer.feed(data);
	self.pump()!;
	return taken;
}

// Executes the buffered complete requests while at least one ADU of output room is left. The room is
// checked BEFORE a frame is taken, so no request is lost. Call it again after draining output(), also when
// no new bytes arrive. A fault (broken MBAP framing) means: close the connection.
// Returns the number of requests handled.
fn usz? ServerConn.pump(&self)
{
	if (self.broken) return modbus::CLOSED~;
	usz handled = 0;
	while (self.out.len - self.out_len >= modbus::MAX_TCP_ADU)
	{
		MbapFrame fr;
		bool? got = self.framer.next(&fr);
		if (catch f = got)
		{
			self.broken = true;
			return f~;
		}
		if (!got) break;
		self.handle(&fr);
		handled++;
	}
	return handled;
}

// Bytes waiting for the transport.
fn char[] ServerConn.output(&self)
{
	return self.out[:self.out_len];
}

// The transport has taken the first n bytes of output().
fn void ServerConn.consume_output(&self, usz n)
{
	if (n >= self.out_len)
	{
		self.out_len = 0;
		return;
	}
	mem::move(&self.out[0], &self.out[n], (sz)(self.out_len - n));
	self.out_len -= n;
}

// ---- request handling ----

fn bool accepts(ServerConfig* config, char unit) @private
{
	if (config.accept_any_unit) return true;
	if (unit == 0) return false;
	foreach (u : config.units)
	{
		if (u == unit) return true;
	}
	return false;
}

// Functions this step answers; every other code gets ILLEGAL_FUNCTION.
fn bool implemented(char fc) @private
{
	return (fc >= 1 && fc <= 6) || fc == 0x08 || fc == 0x0F || fc == 0x10 || fc == 0x11 || fc == 0x16 || fc == 0x17 || fc == 0x2B;
}

fn bool is_write(char fc) @private
{
	return fc == 5 || fc == 6 || fc == 0x0F || fc == 0x10 || fc == 0x16 || fc == 0x17;
}

fn usz exception(char fc, ExceptionCode code, char[] resp) @private
{
	return pdu::encode_exception(fc, code, resp);
}

// Quantity configured below the spec maximum? Read from the raw request, so it is judged before the range.
fn bool over_limit(ServerConfig* config, char[] pdu) @private
{
	char fc = pdu[0];
	if (fc >= 1 && fc <= 4 && pdu.len == 5)
	{
		ushort qty = (ushort)(((ushort)pdu[3] << 8) | pdu[4]);
		ushort lim = fc <= 2 ? config.max_read_bits : config.max_read_regs;
		return lim != 0 && qty > lim;
	}
	if ((fc == 0x0F || fc == 0x10) && pdu.len >= 6)
	{
		ushort qty = (ushort)(((ushort)pdu[3] << 8) | pdu[4]);
		ushort lim = fc == 0x0F ? config.max_write_bits : config.max_write_regs;
		return lim != 0 && qty > lim;
	}
	if (fc == 0x17 && pdu.len >= 10)
	{
		ushort rq = (ushort)(((ushort)pdu[3] << 8) | pdu[4]);
		ushort wq = (ushort)(((ushort)pdu[7] << 8) | pdu[8]);
		return (config.max_read_regs != 0 && rq > config.max_read_regs) || (config.max_write_regs != 0 && wq > config.max_write_regs);
	}
	return false;
}

fn void ServerConn.handle(&self, MbapFrame* fr)
{
	char unit = fr.header.unit;
	if (!accepts(self.config, unit)) return;
	char[] p = fr.pdu;
	char fc = p[0];
	if (fc >= 0x80) return;                     // not a request: no answer
	char[modbus::MAX_PDU] resp;
	usz n = execute(self.config, self.model, unit, p, &resp);
	// the room was checked by pump(): one ADU always fits
	char[] dst = self.out[self.out_len..];
	usz len = frame::mbap_encode(fr.header.tid, unit, resp[:n], dst)!!;
	self.out_len += len;
}

// Runs one request and returns the length of the answer PDU in `resp`.
fn usz execute(ServerConfig* config, DataModel model, char unit, char[] pdu, char[] resp) @private
{
	char fc = pdu[0];
	if (!implemented(fc)) return exception(fc, ExceptionCode.ILLEGAL_FUNCTION, resp);
	if (is_write(fc) && !model.writable(unit)) return exception(fc, ExceptionCode.ILLEGAL_FUNCTION, resp);
	if (over_limit(config, pdu)) return exception(fc, ExceptionCode.ILLEGAL_DATA_VALUE, resp);
	Request? decoded = pdu::decode_request(pdu);
	if (catch f = decoded) return exception(fc, pdu::fault_to_exception(f), resp);
	Request r = decoded;
	ExceptionCode e;
	switch ((Fc)fc)
	{
		case READ_COILS:
		case READ_DISCRETE_INPUTS:
			bool coils = (Fc)fc == Fc.READ_COILS;
			e = model.check_range(unit, coils ? Table.COILS : Table.DISCRETE_INPUTS, r.addr, r.qty);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			bool[modbus::MAX_READ_BITS] bits;
			e = coils ? model.read_coils(unit, r.addr, bits[:r.qty]) : model.read_discrete_inputs(unit, r.addr, bits[:r.qty]);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			usz bytes = ((usz)r.qty + 7) / 8;
			resp[0] = fc;
			resp[1] = (char)bytes;
			for (usz i = 0; i < bytes; i++) resp[2 + i] = 0;
			for (usz i = 0; i < r.qty; i++)
			{
				if (bits[i]) resp[2 + i / 8] |= (char)(1 << (i % 8));
			}
			return 2 + bytes;
		case READ_HOLDING_REGISTERS:
		case READ_INPUT_REGISTERS:
			bool holding = (Fc)fc == Fc.READ_HOLDING_REGISTERS;
			e = model.check_range(unit, holding ? Table.HOLDING_REGISTERS : Table.INPUT_REGISTERS, r.addr, r.qty);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			ushort[modbus::MAX_READ_REGS] regs;
			e = holding ? model.read_holding(unit, r.addr, regs[:r.qty]) : model.read_input(unit, r.addr, regs[:r.qty]);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			resp[0] = fc;
			resp[1] = (char)(r.qty * 2);
			for (usz i = 0; i < r.qty; i++)
			{
				resp[2 + i * 2] = (char)(regs[i] >> 8);
				resp[3 + i * 2] = (char)(regs[i] & 0xFF);
			}
			return 2 + (usz)r.qty * 2;
		case WRITE_SINGLE_COIL:
			e = model.check_range(unit, Table.COILS, r.addr, 1);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			bool[1] one = { r.value == 0xFF00 };
			e = model.write_coils(unit, r.addr, &one);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			return echo(fc, r.addr, r.value, resp);
		case WRITE_SINGLE_REGISTER:
			e = model.check_range(unit, Table.HOLDING_REGISTERS, r.addr, 1);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			ushort[1] reg = { r.value };
			e = model.write_holding(unit, r.addr, &reg);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			return echo(fc, r.addr, r.value, resp);
		case WRITE_MULTIPLE_COILS:
			e = model.check_range(unit, Table.COILS, r.addr, r.qty);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			bool[modbus::MAX_WRITE_BITS] values;
			for (usz i = 0; i < r.qty; i++) values[i] = ((r.data[i / 8] >> (i % 8)) & 1) != 0;
			e = model.write_coils(unit, r.addr, values[:r.qty]);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			return echo(fc, r.addr, r.qty, resp);
		case WRITE_MULTIPLE_REGISTERS:
			e = model.check_range(unit, Table.HOLDING_REGISTERS, r.addr, r.qty);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			ushort[modbus::MAX_WRITE_REGS] words;
			for (usz i = 0; i < r.qty; i++) words[i] = (ushort)(((ushort)r.data[i * 2] << 8) | r.data[i * 2 + 1]);
			e = model.write_holding(unit, r.addr, words[:r.qty]);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			return echo(fc, r.addr, r.qty, resp);
		case MASK_WRITE_REGISTER:
			e = model.check_range(unit, Table.HOLDING_REGISTERS, r.addr, 1);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			ushort[1] old;
			e = model.read_holding(unit, r.addr, &old);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			ushort[1] updated = { (old[0] & r.and_mask) | (r.or_mask & ~r.and_mask) };
			e = model.write_holding(unit, r.addr, &updated);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			resp[0] = fc;
			resp[1] = (char)(r.addr >> 8);
			resp[2] = (char)(r.addr & 0xFF);
			resp[3] = (char)(r.and_mask >> 8);
			resp[4] = (char)(r.and_mask & 0xFF);
			resp[5] = (char)(r.or_mask >> 8);
			resp[6] = (char)(r.or_mask & 0xFF);
			return 7;
		case READ_WRITE_MULTIPLE_REGISTERS:
			// both ranges are checked before anything is written; then write, then read
			e = model.check_range(unit, Table.HOLDING_REGISTERS, r.write_addr, r.write_qty);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			e = model.check_range(unit, Table.HOLDING_REGISTERS, r.addr, r.qty);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			ushort[modbus::MAX_RW_WRITE_REGS] rw_words;
			for (usz i = 0; i < r.write_qty; i++) rw_words[i] = (ushort)(((ushort)r.data[i * 2] << 8) | r.data[i * 2 + 1]);
			e = model.write_holding(unit, r.write_addr, rw_words[:r.write_qty]);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			ushort[modbus::MAX_RW_READ_REGS] rw_regs;
			e = model.read_holding(unit, r.addr, rw_regs[:r.qty]);
			if (e != ExceptionCode.NONE) return exception(fc, e, resp);
			resp[0] = fc;
			resp[1] = (char)(r.qty * 2);
			for (usz i = 0; i < r.qty; i++)
			{
				resp[2 + i * 2] = (char)(rw_regs[i] >> 8);
				resp[3 + i * 2] = (char)(rw_regs[i] & 0xFF);
			}
			return 2 + (usz)r.qty * 2;
		case DIAGNOSTICS:
			// only sub-function 0x0000 (return query data) is answered
			if (!config.allow_diagnostics || r.sub != 0) return exception(fc, ExceptionCode.ILLEGAL_FUNCTION, resp);
			Response echo_rsp = { .fc = fc, .sub = r.sub, .data = r.data };
			return pdu::encode_response(&echo_rsp, resp)!!;
		case REPORT_SERVER_ID:
			if (config.server_id.len == 0) return exception(fc, ExceptionCode.ILLEGAL_FUNCTION, resp);
			Response id_rsp = { .fc = fc, .data = config.server_id };
			return pdu::encode_response(&id_rsp, resp)!!;
		case ENCAPSULATED_INTERFACE:
			return read_device_id(config, r, resp);
		default:
			return exception(fc, ExceptionCode.ILLEGAL_FUNCTION, resp);
	}
}

// First and last object id of what a Read Device ID code covers (basic, regular, extended).
fn void code_range(char code, char* lo, char* hi) @private
{
	switch (code)
	{
		case 1:
			*lo = 0x00;
			*hi = 0x02;
		case 2:
			*lo = 0x03;
			*hi = 0x7F;
		default:
			*lo = 0x80;
			*hi = 0xFF;
	}
}

// FC 43/14 (MAP 6.21). Codes 1 to 3 stream the objects of their range starting at the requested id (an id that is not
// there restarts at the first object of the range); when the next object does not fit the PDU, more-follows is set and
// the id of the next object is returned. Code 4 returns exactly the requested object.
fn usz read_device_id(ServerConfig* config, Request r, char[] resp) @private
{
	char fc = r.fc;
	char[modbus::MAX_PDU] objs;
	usz used = 0;
	usz count = 0;
	bool more = false;
	char next = 0;
	if (r.read_dev_code == 4)
	{
		bool found = false;
		foreach (o : config.device_objects)
		{
			if (o.id != r.object_id) continue;
			objs[0] = o.id;
			objs[1] = (char)o.value.len;
			for (usz i = 0; i < o.value.len; i++) objs[2 + i] = o.value[i];
			used = 2 + o.value.len;
			count = 1;
			found = true;
		}
		if (!found) return exception(fc, ExceptionCode.ILLEGAL_DATA_ADDRESS, resp);
	}
	else
	{
		char lo;
		char hi;
		code_range(r.read_dev_code, &lo, &hi);
		bool known = false;
		foreach (o : config.device_objects)
		{
			if (o.id == r.object_id && o.id >= lo && o.id <= hi) known = true;
		}
		char start = known ? r.object_id : lo;
		foreach (o : config.device_objects)
		{
			if (o.id < start || o.id < lo || o.id > hi) continue;
			if (more) continue;
			if (7 + used + 2 + o.value.len > modbus::MAX_PDU)
			{
				more = true;
				next = o.id;
				continue;
			}
			objs[used] = o.id;
			objs[used + 1] = (char)o.value.len;
			for (usz i = 0; i < o.value.len; i++) objs[used + 2 + i] = o.value[i];
			used += 2 + o.value.len;
			count++;
		}
	}
	Response rsp = {
		.fc = fc,
		.read_dev_code = r.read_dev_code,
		.conformity = config.conformity_level,
		.more_follows = more,
		.next_object_id = next,
		.object_count = (char)count,
		.data = objs[:used],
	};
	return pdu::encode_response(&rsp, resp)!!;
}

// RTU entry point: one frame as delimited by the transport. Returns the length of the answer frame written to
// `out`, or 0 when nothing is to be sent: a bad CRC or a short frame, an address that is not served (248 to 255 are
// reserved), a broadcast (address 0: write functions are executed, nothing is answered, other functions are ignored).
fn usz? handle_rtu(ServerConfig* config, DataModel model, char[] frame, char[] out)
{
	RtuFrame? decoded = frame::rtu_decode(frame);
	if (catch f = decoded) return 0;
	char addr = decoded.addr;
	char[] p = decoded.pdu;
	if (addr >= 248) return 0;
	if (p[0] >= 0x80) return 0;
	bool broadcast = addr == 0;
	if (broadcast)
	{
		if (!is_write(p[0])) return 0;
	}
	else if (!accepts(config, addr))
	{
		return 0;
	}
	char[modbus::MAX_PDU] resp;
	usz n = execute(config, model, addr, p, &resp);
	if (broadcast) return 0;
	return frame::rtu_encode(addr, resp[:n], out)!;
}


// fc, address, value / quantity (the answer of the write functions).
fn usz echo(char fc, ushort addr, ushort value, char[] resp) @private
{
	resp[0] = fc;
	resp[1] = (char)(addr >> 8);
	resp[2] = (char)(addr & 0xFF);
	resp[3] = (char)(value >> 8);
	resp[4] = (char)(value & 0xFF);
	return 5;
}

// ---- in-memory register map ----

// A DataModel over four plain tables (coils, discrete inputs, holding and input registers), one device.
// The tables are public slices: set values directly. Unmapped addresses answer ILLEGAL_DATA_ADDRESS.
struct RegisterMap (DataModel)
{
	Allocator allocator;
	bool[] coils;
	bool[] discrete;
	ushort[] holding;
	ushort[] input;
	bool read_only;             // the whole map takes no writes: every write function answers ILLEGAL_FUNCTION
}

fn void? RegisterMap.init(&self, Allocator allocator, usz ncoils, usz ndiscrete, usz nholding, usz ninput)
{
	*self = {};
	self.allocator = allocator;
	defer catch self.free();        // a failure below gives back the tables allocated before it
	if (ncoils) self.coils = alloc::new_array_try(allocator, bool, (sz)ncoils)!;
	if (ndiscrete) self.discrete = alloc::new_array_try(allocator, bool, (sz)ndiscrete)!;
	if (nholding) self.holding = alloc::new_array_try(allocator, ushort, (sz)nholding)!;
	if (ninput) self.input = alloc::new_array_try(allocator, ushort, (sz)ninput)!;
}

fn void RegisterMap.free(&self)
{
	if (self.coils.ptr) alloc::free(self.allocator, self.coils.ptr);
	if (self.discrete.ptr) alloc::free(self.allocator, self.discrete.ptr);
	if (self.holding.ptr) alloc::free(self.allocator, self.holding.ptr);
	if (self.input.ptr) alloc::free(self.allocator, self.input.ptr);
	*self = {};
}

fn usz RegisterMap.table_len(&self, Table table)
{
	switch (table)
	{
		case COILS: return self.coils.len;
		case DISCRETE_INPUTS: return self.discrete.len;
		case HOLDING_REGISTERS: return self.holding.len;
		case INPUT_REGISTERS: return self.input.len;
	}
}

fn bool RegisterMap.writable(&self, char unit) @dynamic
{
	return !self.read_only;
}

fn ExceptionCode RegisterMap.check_range(&self, char unit, Table table, ushort addr, ushort qty) @dynamic
{
	if ((usz)addr + qty > self.table_len(table)) return ExceptionCode.ILLEGAL_DATA_ADDRESS;
	return ExceptionCode.NONE;
}

fn ExceptionCode RegisterMap.read_coils(&self, char unit, ushort addr, bool[] out) @dynamic
{
	if ((usz)addr + out.len > self.coils.len) return ExceptionCode.ILLEGAL_DATA_ADDRESS;
	for (usz i = 0; i < out.len; i++) out[i] = self.coils[addr + i];
	return ExceptionCode.NONE;
}

fn ExceptionCode RegisterMap.read_discrete_inputs(&self, char unit, ushort addr, bool[] out) @dynamic
{
	if ((usz)addr + out.len > self.discrete.len) return ExceptionCode.ILLEGAL_DATA_ADDRESS;
	for (usz i = 0; i < out.len; i++) out[i] = self.discrete[addr + i];
	return ExceptionCode.NONE;
}

fn ExceptionCode RegisterMap.read_holding(&self, char unit, ushort addr, ushort[] out) @dynamic
{
	if ((usz)addr + out.len > self.holding.len) return ExceptionCode.ILLEGAL_DATA_ADDRESS;
	for (usz i = 0; i < out.len; i++) out[i] = self.holding[addr + i];
	return ExceptionCode.NONE;
}

fn ExceptionCode RegisterMap.read_input(&self, char unit, ushort addr, ushort[] out) @dynamic
{
	if ((usz)addr + out.len > self.input.len) return ExceptionCode.ILLEGAL_DATA_ADDRESS;
	for (usz i = 0; i < out.len; i++) out[i] = self.input[addr + i];
	return ExceptionCode.NONE;
}

// Writes check the whole range first: nothing is written when any address is unmapped.
fn ExceptionCode RegisterMap.write_coils(&self, char unit, ushort addr, bool[] values) @dynamic
{
	if (self.read_only) return ExceptionCode.ILLEGAL_FUNCTION;
	if ((usz)addr + values.len > self.coils.len) return ExceptionCode.ILLEGAL_DATA_ADDRESS;
	for (usz i = 0; i < values.len; i++) self.coils[addr + i] = values[i];
	return ExceptionCode.NONE;
}

fn ExceptionCode RegisterMap.write_holding(&self, char unit, ushort addr, ushort[] values) @dynamic
{
	if (self.read_only) return ExceptionCode.ILLEGAL_FUNCTION;
	if ((usz)addr + values.len > self.holding.len) return ExceptionCode.ILLEGAL_DATA_ADDRESS;
	for (usz i = 0; i < values.len; i++) self.holding[addr + i] = values[i];
	return ExceptionCode.NONE;
}
