module modbus::tcp;

import std::io;
import std::net;
import std::net::os;
import std::time;
import std::core::mem;
import modbus;
import modbus::client;
import modbus::pdu;
import modbus::server;
import modbus::transport;

// Blocking TCP adapter over std::net. The timeouts use poll (POSIX) / WSAPoll (Windows) through std::net::poll;
// this is the only file of the library that touches sockets.

// ---- TcpTransport ----

struct TcpTransport (Transport)
{
	TcpSocket socket;
	bool open;
}

// A Duration of std::net::POLL_FOREVER waits without limit; any other negative Duration counts as zero.
fn Duration sanitize(Duration t) @private
{
	if (t == net::POLL_FOREVER) return t;
	if (t < time::DURATION_ZERO) return time::DURATION_ZERO;
	return t;
}

// Waits until the socket is ready for `what`. false: the time ran out.
fn bool? wait_socket(TcpSocket* socket, PollSubscribe what, Duration timeout) @private
{
	Poll[1] p = { { .socket = socket.sock, .events = what } };
	ulong n = net::poll(&p, sanitize(timeout))!;
	return n > 0;
}

// Connects (timeout 0 waits as long as the system allows) and sets TCP_NODELAY.
fn void? TcpTransport.connect(&self, String host, ushort port, Duration timeout)
{
	self.socket = tcp::connect(host, port, timeout)!;
	self.open = true;
	(void)self.set_nodelay(true);
}

// Takes over a connected socket (accepted by a server).
fn void TcpTransport.adopt(&self, TcpSocket socket)
{
	self.socket = socket;
	self.open = true;
	(void)self.set_nodelay(true);
}

// TCP_NODELAY (IPPROTO_TCP = 6, TCP_NODELAY = 1 on Linux, macOS and Windows): a request is one small write and
// must not wait for the delayed-ACK timer of the peer.
fn void? TcpTransport.set_nodelay(&self, bool on)
{
	CInt flag = (CInt)on;
	if (os::setsockopt(self.socket.sock, 6, 1, &flag, CInt::size) != 0) return net::SOCKOPT_FAILED~;
}

fn usz? TcpTransport.read(&self, char[] buf, Duration timeout) @dynamic
{
	if (!self.open) return modbus::CLOSED~;
	if (buf.len == 0) return 0;
	bool? ready = wait_socket(&self.socket, PollSubscribe.READ, timeout);
	if (catch f = ready) return modbus::CLOSED~;
	if (!ready) return modbus::TIMEOUT~;
	sz? n = self.socket.read(buf);
	if (catch f = n) return modbus::CLOSED~;
	if (n <= 0) return modbus::CLOSED~;           // EOF
	return (usz)n;
}

// Each wait for room in the socket buffer is limited by `timeout`.
fn void? TcpTransport.write(&self, char[] data, Duration timeout) @dynamic
{
	if (!self.open) return modbus::CLOSED~;
	char[] rest = data;
	while (rest.len > 0)
	{
		bool? ready = wait_socket(&self.socket, PollSubscribe.WRITE, timeout);
		if (catch f = ready) return modbus::CLOSED~;
		if (!ready) return modbus::TIMEOUT~;
		sz? n = self.socket.write(rest);
		if (catch f = n) return modbus::CLOSED~;
		if (n <= 0) return modbus::CLOSED~;
		rest = rest[(usz)n..];
	}
}

// Non-blocking mode, for sockets that a single-threaded server serves.
fn void? TcpTransport.set_non_blocking(&self)
{
	self.socket.sock.set_non_blocking(true)!;
}

// One send of what the socket takes right now: the number of bytes written, 0 when it has no room
// (a non-blocking socket) or the call was interrupted. CLOSED on any other error.
fn usz? TcpTransport.write_some(&self, char[] data)
{
	if (!self.open) return modbus::CLOSED~;
	sz? n = self.socket.write(data);
	if (catch f = n)
	{
		if (f == io::WOULD_BLOCK || f == io::INTERRUPTED) return 0;
		return modbus::CLOSED~;
	}
	return n < 0 ? 0 : (usz)n;
}

fn void? TcpTransport.close(&self) @dynamic
{
	if (!self.open) return;
	self.open = false;
	(void)self.socket.close();
}

// ---- BlockingClient ----

// Client + Transport: one call = send, wait, decode. Use Client directly to pipeline.
struct BlockingClient
{
	Client core;
	Transport transport;
	ClockFn clock;              // the only place time enters: monotonic clock; tests replace it
}

fn void? BlockingClient.init(&self, Transport transport, ClientConfig config, Allocator allocator)
{
	if (config.framing != TCP) return modbus::BAD_VALUE~;     // this client reads a byte stream of MBAP frames
	*self = {};
	self.transport = transport;
	self.clock = &modbus::real_clock;
	self.core.init(config, allocator)!;
}

fn void BlockingClient.free(&self)
{
	self.core.free();
}

// Sends the request and waits for its answer. The Response borrows the receive buffer of the client and is valid
// until the next call. REMOTE_EXCEPTION: the peer answered with an exception, its code is stored in *exc.
// WRITE_NOT_ALLOWED: the write guard refused the request (nothing was sent). TIMEOUT: no answer in config.timeout;
// the connection stays usable. CLOSED: the peer closed or broke the stream: connect again.
fn Response? BlockingClient.call(&self, Request* req, ExceptionCode* exc)
{
	Clock start = self.clock();
	self.core.send(req, start, 0)!;
	char[] out = self.core.output();
	usz queued = out.len;
	if (catch f = self.transport.write(out, self.core.config.timeout))
	{
		self.core.consume_output(queued);
		self.core.fail_all(modbus::CLOSED);
		return modbus::is_timeout(f) ? modbus::TIMEOUT~ : modbus::CLOSED~;
	}
	self.core.consume_output(queued);
	char[2048] rx;
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
					// a late answer to an earlier, timed-out request is not ours: skip it
					if (!ev.fatal && ev.error == modbus::UNKNOWN_TRANSACTION) continue;
					return ev.error~;
			}
		}
		Clock deadline;
		if (!self.core.next_deadline(&deadline)) return modbus::CLOSED~;
		Duration wait = time::DURATION_ZERO;
		if ((long)deadline > (long)now) wait = deadline.nano_diff(now).to_duration();
		usz room = self.core.framer.free_space();
		if (room > rx.len) room = rx.len;
		usz? n = self.transport.read(rx[:room], wait);
		if (catch f = n)
		{
			// a timeout is not an error by itself: poll() expires the request once its deadline has passed
			if (!modbus::is_timeout(f)) self.core.fail_all(modbus::CLOSED);
			continue;
		}
		usz taken = self.core.feed(rx[:n])!;
		assert(taken == n);
	}
}

// Device identification (MAP 6.21): repeats the request while more-follows is set. Objects are copied into `objs`,
// their bytes into `text`; returns the object count. MISMATCH when the next object id does not advance past the id
// that was just asked for (no progress) or after max_rounds requests. BUFFER_TOO_SMALL when objs or text are full.
fn usz? BlockingClient.read_device_id_all(&self, char code, usz max_rounds, pdu::DeviceObject[] objs, char[] text)
{
	usz count = 0;
	usz used = 0;
	char next = 0;
	for (usz round = 0; round < max_rounds; round++)
	{
		Request req = pdu::read_device_id(code, next);
		ExceptionCode exc;
		Response rsp = self.call(&req, &exc)!;
		pdu::ObjectIter it = pdu::objects(&rsp);
		pdu::DeviceObject o;
		while (it.next(&o)!)
		{
			if (count >= objs.len || used + o.value.len > text.len) return modbus::BUFFER_TOO_SMALL~;
			for (usz i = 0; i < o.value.len; i++) text[used + i] = o.value[i];
			objs[count] = { o.id, (String)text[used:o.value.len] };
			used += o.value.len;
			count++;
		}
		if (!rsp.more_follows) return count;
		if (rsp.next_object_id <= next) return modbus::MISMATCH~;
		next = rsp.next_object_id;
	}
	return modbus::MISMATCH~;
}

// ---- TcpServer ----

const usz MAX_CONNECTIONS = 8;

struct TcpConn
{
	TcpTransport io;
	ServerConn session;
	bool used;
	Clock last_active;       // last time bytes arrived or left
	Clock blocked_since;     // output pending and the socket took nothing since then
	bool blocked;
}

// Accepts connections (up to 8) and serves each with its own ServerConn, one poll round at a time. No threads:
// serve_once() is one round, serve() loops over it. Sockets are non-blocking, so one slow client never holds the
// others up: what the socket does not take stays in the session output, the connection is not read from until
// it is gone, and it is dropped when its output makes no progress for `write_timeout`.
// A connection that is silent for `idle_timeout` is dropped too (zero switches that off), which frees its slot:
// a full server turns new clients away until then.
struct TcpServer
{
	TcpServerSocket listener;
	ServerConfig* config;
	DataModel model;
	Allocator allocator;
	Duration write_timeout;  // default 5 s
	Duration idle_timeout;   // default 60 s
	ClockFn clock;           // monotonic clock; tests replace it
	TcpConn[MAX_CONNECTIONS] conns;
}

fn void? TcpServer.init(&self, TcpServerSocket listener, ServerConfig* config, DataModel model, Allocator allocator)
{
	config.check()!;
	*self = {};
	self.listener = listener;
	self.config = config;
	self.model = model;
	self.allocator = allocator;
	self.write_timeout = time::sec(5);
	self.idle_timeout = time::sec(60);
	self.clock = &modbus::real_clock;
}

// Closes every connection and the listener.
fn void TcpServer.close(&self)
{
	foreach (&c : self.conns)
	{
		if (c.used) self.drop(c);
	}
	(void)self.listener.close();
}

fn usz TcpServer.connection_count(&self)
{
	usz n = 0;
	foreach (&c : self.conns)
	{
		if (c.used) n++;
	}
	return n;
}

// Connections with answers the socket has not taken yet.
fn usz TcpServer.blocked_connections(&self)
{
	usz n = 0;
	foreach (&c : self.conns)
	{
		if (c.used && c.session.output().len > 0) n++;
	}
	return n;
}

fn void TcpServer.drop(&self, TcpConn* c)
{
	c.session.free();
	(void)c.io.close();
	c.used = false;
}

fn Duration since(Clock now, Clock then) @private
{
	return now.nano_diff(then).to_duration();
}

// Hands the socket what it takes. false: the connection was dropped.
fn bool TcpServer.flush(&self, TcpConn* c, Clock now)
{
	char[] out = c.session.output();
	if (out.len == 0)
	{
		c.blocked = false;
		return true;
	}
	usz? n = c.io.write_some(out);
	if (catch f = n)
	{
		self.drop(c);
		return false;
	}
	if (n > 0)
	{
		c.session.consume_output(n);
		c.last_active = now;
		c.blocked_since = now;
	}
	if (c.session.output().len == 0)
	{
		c.blocked = false;
		return true;
	}
	if (!c.blocked)
	{
		c.blocked = true;
		c.blocked_since = now;
	}
	return true;
}

// Answers the buffered requests and writes the answers while the socket takes them. false: dropped.
fn bool TcpServer.pump_flush(&self, TcpConn* c, Clock now)
{
	while (true)
	{
		usz? handled = c.session.pump();
		if (catch f = handled)
		{
			self.drop(c);
			return false;
		}
		if (!self.flush(c, now)) return false;
		if (c.session.output().len > 0 || handled == 0) return true;
	}
}

// Reads what is there (never more than the session can buffer) and feeds it. false: dropped.
fn bool TcpServer.read_some(&self, TcpConn* c, Clock now)
{
	usz room = c.session.framer.free_space();
	if (room == 0) return true;
	char[2048] buf;
	if (room > buf.len) room = buf.len;
	usz? n = c.io.read(buf[:room], time::DURATION_ZERO);
	if (catch f = n)
	{
		if (modbus::is_timeout(f)) return true;
		self.drop(c);
		return false;
	}
	c.last_active = now;
	usz? taken = c.session.feed(buf[:n]);
	if (catch f = taken)
	{
		self.drop(c);
		return false;
	}
	return true;
}

fn void TcpServer.service(&self, TcpConn* c, bool ready, Clock now)
{
	if (ready && c.session.output().len == 0 && !self.read_some(c, now)) return;
	if (!self.pump_flush(c, now)) return;
	if (c.blocked && since(now, c.blocked_since) > self.write_timeout)
	{
		self.drop(c);                       // the peer does not take its answers
		return;
	}
	if (self.idle_timeout > time::DURATION_ZERO && c.session.output().len == 0 && since(now, c.last_active) > self.idle_timeout)
	{
		self.drop(c);                       // silent for too long: give the slot back
	}
}

// One round: waits up to `timeout` for a new connection or for data, then serves what is ready.
fn void? TcpServer.serve_once(&self, Duration timeout)
{
	Poll[1 + MAX_CONNECTIONS] polls;
	usz[1 + MAX_CONNECTIONS] owner;
	polls[0] = { .socket = self.listener.sock, .events = PollSubscribe.READ };
	usz n = 1;
	foreach (i, &c : self.conns)
	{
		if (!c.used) continue;
		// a connection with pending answers is watched for room to write, not for more requests
		PollSubscribe what = c.session.output().len > 0 ? PollSubscribe.WRITE : PollSubscribe.READ;
		polls[n] = { .socket = c.io.socket.sock, .events = what };
		owner[n] = (usz)i;
		n++;
	}
	ulong ready = net::poll(polls[:n], sanitize(timeout))!;
	Clock now = self.clock();
	if ((ushort)polls[0].revents != 0)
	{
		TcpSocket? s = tcp::accept(&self.listener);
		if (try accepted = s)
		{
			TcpConn* slot = null;
			foreach (&c : self.conns)
			{
				if (!c.used)
				{
					slot = c;
					break;
				}
			}
			if (slot && @ok(slot.session.init(self.config, self.model, self.allocator)))
			{
				slot.io.adopt(accepted);
				if (@ok(slot.io.set_non_blocking()))
				{
					slot.used = true;
					slot.last_active = now;
					slot.blocked = false;
				}
				else
				{
					slot.session.free();
					(void)slot.io.close();
				}
			}
			else
			{
				TcpSocket dropped = accepted;
				(void)dropped.close();
			}
		}
	}
	bool[1 + MAX_CONNECTIONS] hit;
	for (usz k = 1; k < n; k++) hit[owner[k]] = (ushort)polls[k].revents != 0;
	foreach (i, &c : self.conns)
	{
		if (c.used) self.service(c, hit[i], now);
	}
}

// Serves until *stop becomes true (checked every 100 ms).
fn void? TcpServer.serve(&self, bool* stop)
{
	while (!*stop) self.serve_once(time::ms(100))!;
}
