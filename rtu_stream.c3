module modbus::rtu_stream;

import std::core::mem;
import std::time;
import modbus;
import modbus::client;
import modbus::frame;
import modbus::pdu;
import modbus::server;
import modbus::transport;

// Modbus RTU over a byte stream (a serial port, or RTU framing over TCP). RTU frames have no length field: a frame
// ends when the line is silent for 3.5 character times (Modbus over Serial Line 2.5.1.1). The adapter takes that
// gap as a parameter (about 1.75 ms at 19200 baud; 5 to 20 ms is usual over TCP gateways) and uses the plain
// Transport: a read that faults TIMEOUT after `gap` ends the frame. A serial transport reuses it unchanged.

// Frames a Transport by silence.
struct RtuStream
{
	Transport transport;
	Duration gap;            // silence that ends a frame, and the quiet time before a request is sent
	Duration write_timeout;  // time allowed to write an answer in serve_rtu_once (default 1 s)
}

fn void RtuStream.init(&self, Transport transport, Duration gap)
{
	self.transport = transport;
	self.gap = gap;
	self.write_timeout = time::sec(1);
}

// Waits up to `wait` for the first byte (TIMEOUT when nothing comes), then collects bytes until the line has been
// silent for `gap`. Returns the frame length. A frame longer than `out` is read to its end and refused (BAD_LENGTH);
// so is a line that keeps sending: after `2 * out.len + 64` bytes the read gives up.
// CLOSED when the stream ended before any byte; bytes that arrived before the end are returned first.
fn usz? RtuStream.read_frame(&self, char[] out, Duration wait)
{
	usz? first = self.transport.read(out, wait);
	if (catch f = first) return modbus::is_timeout(f) ? modbus::TIMEOUT~ : modbus::CLOSED~;
	usz n = first;
	usz total = n;
	usz budget = 2 * out.len + 64;      // a line that never goes silent is refused after this many bytes
	bool too_long = false;
	char[64] sink;
	while (true)
	{
		usz? more = n < out.len ? self.transport.read(out[n..], self.gap) : self.transport.read(&sink, self.gap);
		if (catch f = more) break;          // silence ends the frame; a closed stream is reported by the next call
		if (n < out.len)
		{
			n += more;
		}
		else
		{
			too_long = true;
		}
		total += more;
		if (total >= budget)
		{
			too_long = true;
			break;
		}
	}
	if (too_long) return modbus::BAD_LENGTH~;
	return n;
}

// Throws away what is waiting on the line: reads until it has been silent for `gap`.
fn void RtuStream.flush_input(&self)
{
	char[64] sink;
	while (@ok(self.transport.read(&sink, self.gap))) {}
}

// Sends one frame after the line was silent for `gap` (stale bytes of an earlier answer are discarded first, so
// a late reply cannot be taken for the answer to this request).
fn void? RtuStream.write_frame(&self, char[] frame, Duration timeout)
{
	self.flush_input();
	self.transport.write(frame, timeout)!;
}

// ---- RTU client ----

// Client over RTU: one request at a time, matched by (unit, function). A late reply after a timeout can still
// match the next identical request to the same unit: write_frame's quiet gap removes it before the next request
// is sent, but a reply that arrives later than that cannot be told apart (inherent to RTU).
struct RtuClient
{
	Client core;
	RtuStream stream;
	ClockFn clock;           // the only place time enters; default: monotonic clock
}

fn void? RtuClient.init(&self, Transport transport, ClientConfig config, Duration gap, Allocator allocator)
{
	*self = {};
	config.framing = RTU;
	self.stream.init(transport, gap);
	self.clock = &modbus::real_clock;
	self.core.init(config, allocator)!;
}

fn void RtuClient.free(&self)
{
	self.core.free();
}

// Sends a write to every device (unit 0): nothing is answered and nothing is awaited. The caller waits the
// turnaround time itself before the next request (Modbus over Serial Line 2.4.1).
fn void? RtuClient.broadcast(&self, Request* req)
{
	self.core.send(req, self.clock(), 0, 0)!;
	char[] out = self.core.output();
	usz queued = out.len;
	defer self.core.consume_output(queued);
	self.stream.write_frame(out, self.core.config.timeout)!;
}

// Sends the request to `unit` (-1: the configured unit; 0 is a broadcast: use broadcast()) and waits for the answer.
// The Response borrows the client's buffer until the next call. Faults as BlockingClient.call: REMOTE_EXCEPTION
// (code in *exc), WRITE_NOT_ALLOWED, TIMEOUT, CLOSED. A frame with a bad CRC is dropped; the request then times out.
fn Response? RtuClient.call(&self, Request* req, ExceptionCode* exc, int unit = -1)
{
	if ((unit < 0 ? self.core.config.unit : unit) == 0) return modbus::BAD_VALUE~;    // unit 0 is the broadcast: use broadcast()
	self.core.send(req, self.clock(), 0, unit)!;
	char[] out = self.core.output();
	usz queued = out.len;
	if (catch f = self.stream.write_frame(out, self.core.config.timeout))
	{
		self.core.consume_output(queued);
		self.core.fail_all(modbus::CLOSED);
		return modbus::is_timeout(f) ? modbus::TIMEOUT~ : modbus::CLOSED~;
	}
	self.core.consume_output(queued);
	char[modbus::MAX_RTU_ADU] rx;
	while (true)
	{
		Clock now = self.clock();
		Event ev;
		if (self.core.poll(now, &ev))
		{
			switch (ev.kind)
			{
				case RESPONSE:
					return ev.response;
				case EXCEPTION:
					*exc = ev.response.exception;
					return modbus::REMOTE_EXCEPTION~;
				case TIMEOUT:
					return modbus::TIMEOUT~;
				case PROTOCOL_ERROR:
					// not the answer to this request (bad CRC, wrong unit, stray frame): keep waiting for its deadline.
					// When the request is no longer pending, its own answer was bad: that is the result.
					if (!ev.fatal && self.core.pending_count() > 0) continue;
					return ev.error~;
			}
		}
		Clock deadline;
		if (!self.core.next_deadline(&deadline)) return modbus::CLOSED~;
		Duration wait = time::DURATION_ZERO;
		if ((long)deadline > (long)now) wait = deadline.nano_diff(now).to_duration();
		usz? n = self.stream.read_frame(&rx, wait);
		if (catch f = n)
		{
			if (f == modbus::TIMEOUT) continue;        // poll() expires the request once its deadline has passed
			if (f == modbus::BAD_LENGTH) continue;     // an over-long frame is noise
			self.core.fail_all(modbus::CLOSED);
			continue;
		}
		self.core.feed_frame(rx[:n])!;
	}
}

// ---- RTU server ----

// One step of an RTU device: waits up to `wait` for a frame, executes it and writes the answer. Nothing happens
// (and no fault is returned) when no frame arrives in time, when it is not for this device, has a bad CRC, or is
// a broadcast. CLOSED when the stream ends.
fn void? serve_rtu_once(RtuStream* stream, ServerConfig* config, DataModel model, Duration wait)
{
	char[modbus::MAX_RTU_ADU] frame;
	usz? n = stream.read_frame(&frame, wait);
	if (catch f = n)
	{
		if (f == modbus::TIMEOUT || f == modbus::BAD_LENGTH) return;
		return f~;
	}
	char[modbus::MAX_RTU_ADU] answer;
	usz len = server::handle_rtu(config, model, frame[:n], &answer)!;
	if (len > 0) stream.transport.write(answer[:len], stream.write_timeout)!;
}
