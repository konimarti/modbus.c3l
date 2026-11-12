module modbus::client;

import std::core::mem;
import std::core::mem::alloc;
import std::time;
import modbus, modbus::pdu, modbus::frame;

enum Framing { TCP, RTU }

struct ClientConfig
{
	Framing framing;
	char unit;              // default unit id (MBAP unit / RTU address); send(unit = -1) uses it
	usz max_pending;        // pipeline depth (RTU always uses 1)
	Duration timeout;       // per request
	bool allow_write;       // default false: send() refuses write functions with WRITE_NOT_ALLOWED
	bool check_unit;        // true: a response with another unit id is a MISMATCH; false: accept (gateways)
	usz output_size;        // bytes of output buffer; 0: max_pending * 260 (TCP) / 256 (RTU)
}

// Defaults: TCP, unit 1, max_pending 1, timeout 2 s, check_unit true, allow_write false.
fn ClientConfig default_config()
{
	return { .framing = TCP, .unit = 1, .max_pending = 1, .timeout = time::sec(2), .allow_write = false, .check_unit = true };
}

enum EventKind { RESPONSE, EXCEPTION, TIMEOUT, PROTOCOL_ERROR }

struct Event
{
	EventKind kind;
	ulong cookie;           // caller's value from send()
	ushort tid;
	char unit;
	Request request;        // copy of the request header (data not kept: always empty)
	Response response;      // RESPONSE / EXCEPTION; data borrowed until the next feed()/poll()
	fault error;            // TIMEOUT / PROTOCOL_ERROR: the fault (BAD_PROTOCOL_ID, MISMATCH, UNKNOWN_TRANSACTION, ...)
	bool fatal;             // true: the stream is broken, every pending slot also fails
}

struct Pending
{
	bool used;
	ushort tid;
	char unit;
	ulong cookie;
	Clock deadline;
	Request request;
	char[250] diag;         // FC 8: the request data, needed to check the echo
}

// Sans-IO client. Caller: send() -> drain output() to the transport -> feed() what arrives ->
// poll() for events; use next_deadline() to size the transport wait. Never reads a clock.
struct Client
{
	ClientConfig config;
	Allocator allocator;
	Pending[] pending;
	char[] out;             // bytes waiting for the transport
	usz out_len;
	MbapFramer framer;
	char[modbus::MAX_RTU_ADU] rtu_buf;   // RTU: the one frame waiting for poll()
	usz rtu_len;
	bool rtu_has;
	ushort next_tid;
	bool broken;
	fault broken_fault;
}

fn bool is_write_fc(char code) @private
{
	Fc fc = (Fc)code;
	return fc == Fc.WRITE_SINGLE_COIL || fc == Fc.WRITE_SINGLE_REGISTER || fc == Fc.WRITE_MULTIPLE_COILS
		|| fc == Fc.WRITE_MULTIPLE_REGISTERS || fc == Fc.MASK_WRITE_REGISTER || fc == Fc.READ_WRITE_MULTIPLE_REGISTERS;
}

// Allocates the slots and the output buffer once. BUFFER_TOO_SMALL when output_size cannot hold one ADU.
fn void? Client.init(&self, ClientConfig config, Allocator allocator)
{
	if (config.framing == RTU) config.max_pending = 1;
	if (config.max_pending < 1) return modbus::BAD_VALUE~;
	usz adu = config.framing == TCP ? modbus::MAX_TCP_ADU : modbus::MAX_RTU_ADU;
	if (config.output_size == 0) config.output_size = config.max_pending * adu;
	if (config.output_size < adu) return modbus::BUFFER_TOO_SMALL~;
	*self = {};
	self.config = config;
	self.allocator = allocator;
	defer catch self.free();        // a failure below gives back what was allocated before it
	self.pending = alloc::new_array_try(allocator, Pending, (sz)config.max_pending)!;
	self.out = alloc::new_array_try(allocator, char, (sz)config.output_size)!;
	self.next_tid = 1;
}

fn void Client.free(&self)
{
	if (self.pending.ptr) alloc::free(self.allocator, self.pending.ptr);
	if (self.out.ptr) alloc::free(self.allocator, self.out.ptr);
	self.pending = {};
	self.out = {};
	self.out_len = 0;
}

fn bool tid_in_use(Client* c, ushort tid) @private
{
	foreach (&p : c.pending)
	{
		if (p.used && p.tid == tid) return true;
	}
	return false;
}

fn Pending* Client.free_slot(&self)
{
	foreach (&p : self.pending)
	{
		if (!p.used) return p;
	}
	return null;
}

// Queues one request. Returns the transaction id (TCP), or 0 (RTU, where no id exists and for a broadcast).
// Checked before anything is queued: broken stream, request limits, write guard, free slot, output room.
fn ushort? Client.send(&self, Request* req, Clock now, ulong cookie = 0, int unit = -1)
{
	if (self.broken) return modbus::CLOSED~;
	if (unit < -1 || unit > 255) return modbus::BAD_VALUE~;
	char u = unit < 0 ? self.config.unit : (char)unit;
	char[modbus::MAX_PDU] pdu_buf;
	usz n = pdu::encode_request(req, &pdu_buf)!;
	if (is_write_fc(req.fc) && !self.config.allow_write) return modbus::WRITE_NOT_ALLOWED~;
	bool rtu = self.config.framing == RTU;
	bool broadcast = rtu && u == 0;
	if (broadcast && !is_write_fc(req.fc)) return modbus::BAD_VALUE~;   // only writes can be broadcast
	Pending* slot = null;
	if (!broadcast)
	{
		slot = self.free_slot();
		if (!slot) return modbus::TOO_MANY_PENDING~;
	}
	usz adu = rtu ? n + 3 : n + modbus::MBAP_LEN;
	if (self.out.len - self.out_len < adu) return modbus::OUTPUT_FULL~;
	ushort tid = 0;
	char[] dst = self.out[self.out_len..];
	if (rtu)
	{
		frame::rtu_encode(u, pdu_buf[:n], dst)!;
	}
	else
	{
		while (true)
		{
			tid = self.next_tid;
			self.next_tid++;
			if (!tid_in_use(self, tid)) break;
		}
		frame::mbap_encode(tid, u, pdu_buf[:n], dst)!;
	}
	self.out_len += adu;
	if (slot)
	{
		*slot = {};
		slot.used = true;
		slot.tid = tid;
		slot.unit = u;
		slot.cookie = cookie;
		slot.deadline = now.add_duration(self.config.timeout);
		slot.request = *req;
		slot.request.data = {};
		if ((Fc)req.fc == Fc.DIAGNOSTICS)
		{
			mem::copy(&slot.diag[0], req.data.ptr, (sz)req.data.len);
			slot.request.data = slot.diag[:req.data.len];
		}
	}
	return tid;
}

// Bytes waiting for the transport.
fn char[] Client.output(&self)
{
	return self.out[:self.out_len];
}

// The transport has taken the first n bytes of output().
fn void Client.consume_output(&self, usz n)
{
	if (n >= self.out_len)
	{
		self.out_len = 0;
		return;
	}
	mem::move(&self.out[0], &self.out[n], (sz)(self.out_len - n));
	self.out_len -= n;
}

// TCP: appends to the framer only and returns the bytes taken (less than data.len when the framer is full:
// poll() first, then feed the rest). Frames are decoded by poll(), one per call.
fn usz? Client.feed(&self, char[] data)
{
	if (self.broken) return modbus::CLOSED~;
	if (self.config.framing != TCP) return modbus::BAD_VALUE~;
	return self.framer.feed(data);
}

// RTU: one frame delimited by the transport; kept for the next poll(). A second frame before poll() -> OUTPUT_FULL.
fn void? Client.feed_frame(&self, char[] frame)
{
	if (self.broken) return modbus::CLOSED~;
	if (self.config.framing != RTU) return modbus::BAD_VALUE~;
	if (self.rtu_has) return modbus::OUTPUT_FULL~;
	if (frame.len > self.rtu_buf.len) return modbus::BAD_LENGTH~;
	mem::copy(&self.rtu_buf[0], frame.ptr, (sz)frame.len);
	self.rtu_len = frame.len;
	self.rtu_has = true;
}

fn void Client.fill(&self, Event* ev, Pending* slot)
{
	ev.cookie = slot.cookie;
	ev.tid = slot.tid;
	ev.unit = slot.unit;
	ev.request = slot.request;
	ev.request.data = {};
}

// Completes `slot` with a decoded response (or exception) for `pdu`, or with a non-fatal protocol error.
fn void Client.finish(&self, Event* ev, Pending* slot, char[] pdu)
{
	self.fill(ev, slot);
	Request req = slot.request;       // keeps the FC 8 data (owned by the slot) for the echo check
	slot.used = false;
	Response? rsp = pdu::decode_response(&req, pdu);
	if (catch f = rsp)
	{
		ev.kind = PROTOCOL_ERROR;
		ev.error = f;
		return;
	}
	ev.response = rsp;
	ev.kind = rsp.is_exception ? EXCEPTION : RESPONSE;
}

fn void Client.stream_error(&self, Event* ev, fault f)
{
	self.broken = true;
	self.broken_fault = f;
	ev.kind = PROTOCOL_ERROR;
	ev.error = f;
	ev.fatal = true;
}

// Decodes one buffered frame or expires one timeout per call; call until it returns false.
// ev.response.data stays valid until the next poll()/feed().
fn bool Client.poll(&self, Clock now, Event* ev)
{
	*ev = {};
	if (self.broken)
	{
		// every pending slot fails once, with the fault that broke the stream
		foreach (&p : self.pending)
		{
			if (!p.used) continue;
			self.fill(ev, p);
			p.used = false;
			ev.kind = PROTOCOL_ERROR;
			ev.error = self.broken_fault;
			ev.fatal = true;
			return true;
		}
		return false;
	}
	if (self.config.framing == TCP)
	{
		MbapFrame fr;
		bool? got = self.framer.next(&fr);
		if (catch f = got)
		{
			self.stream_error(ev, f);
			return true;
		}
		if (got)
		{
			ev.tid = fr.header.tid;
			ev.unit = fr.header.unit;
			Pending* slot = null;
			foreach (&p : self.pending)
			{
				if (p.used && p.tid == fr.header.tid) slot = p;
			}
			if (!slot)
			{
				ev.kind = PROTOCOL_ERROR;
				ev.error = modbus::UNKNOWN_TRANSACTION;
				return true;
			}
			if (self.config.check_unit && fr.header.unit != slot.unit)
			{
				self.fill(ev, slot);
				slot.used = false;
				ev.unit = fr.header.unit;
				ev.kind = PROTOCOL_ERROR;
				ev.error = modbus::MISMATCH;
				return true;
			}
			self.finish(ev, slot, fr.pdu);
			return true;
		}
	}
	else if (self.rtu_has)
	{
		self.rtu_has = false;
		RtuFrame? fr = frame::rtu_decode(self.rtu_buf[:self.rtu_len]);
		if (catch f = fr)
		{
			ev.kind = PROTOCOL_ERROR;
			ev.error = f;
			return true;
		}
		Pending* slot = &self.pending[0];
		ev.unit = fr.addr;
		if (!slot.used || fr.addr != slot.unit || (fr.pdu[0] & 0x7F) != slot.request.fc)
		{
			ev.kind = PROTOCOL_ERROR;
			ev.error = modbus::UNKNOWN_TRANSACTION;
			return true;
		}
		self.finish(ev, slot, fr.pdu);
		return true;
	}
	// timeouts: the earliest expired slot first
	Pending* due = null;
	foreach (&p : self.pending)
	{
		if (!p.used || (long)p.deadline > (long)now) continue;
		if (!due || (long)p.deadline < (long)due.deadline) due = p;
	}
	if (due)
	{
		self.fill(ev, due);
		due.used = false;
		ev.kind = TIMEOUT;
		ev.error = modbus::TIMEOUT;
		return true;
	}
	return false;
}

// Transport EOF/error: every pending slot yields one fatal PROTOCOL_ERROR event carrying `f` on the
// following poll() calls; the client is broken (send/feed fault with CLOSED).
fn void Client.fail_all(&self, fault f)
{
	self.broken = true;
	self.broken_fault = f;
}

// false: nothing pending; else *out is the earliest absolute deadline.
fn bool Client.next_deadline(&self, Clock* out)
{
	bool found = false;
	foreach (&p : self.pending)
	{
		if (!p.used) continue;
		if (!found || (long)p.deadline < (long)*out) *out = p.deadline;
		found = true;
	}
	return found;
}

fn usz Client.pending_count(&self)
{
	usz n = 0;
	foreach (&p : self.pending)
	{
		if (p.used) n++;
	}
	return n;
}
