module modbus::tcp;

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

fn void? TcpTransport.close(&self) @dynamic
{
	if (!self.open) return;
	self.open = false;
	(void)self.socket.close();
}

// ---- BlockingClient ----

alias ClockFn = fn Clock();

fn Clock real_clock() @private
{
	return clock::now();
}

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
	self.clock = &real_clock;
	self.core.init(config, allocator)!;
}

fn void BlockingClient.free(&self)
{
	self.core.free();
}

// A fault of another library's transport has its own identity; they are matched by name.
fn bool is_timeout(fault f) @private
{
	return f == modbus::TIMEOUT || f.short_name() == "TIMEOUT";
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
		return is_timeout(f) ? modbus::TIMEOUT~ : modbus::CLOSED~;
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
			if (!is_timeout(f)) self.core.fail_all(modbus::CLOSED);
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
}

// Accepts connections (up to 8) and serves each with its own ServerConn, one poll round at a time. No threads:
// serve_once() is one round, serve() loops over it.
struct TcpServer
{
	TcpServerSocket listener;
	ServerConfig* config;
	DataModel model;
	Allocator allocator;
	Duration write_timeout;
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
	self.write_timeout = time::sec(1);
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

fn void TcpServer.drop(&self, TcpConn* c)
{
	c.session.free();
	(void)c.io.close();
	c.used = false;
}

// Feeds what arrived, answers every complete request, writes the answers. A fault drops the connection.
fn void TcpServer.service(&self, TcpConn* c)
{
	char[2048] buf;
	usz? n = c.io.read(&buf, time::DURATION_ZERO);
	if (catch f = n)
	{
		if (!is_timeout(f)) self.drop(c);
		return;
	}
	char[] rest = buf[:n];
	while (true)
	{
		usz taken = 0;
		usz handled = 0;
		if (rest.len > 0)
		{
			usz? t = c.session.feed(rest);
			if (catch f = t)
			{
				self.drop(c);
				return;
			}
			taken = t;
			rest = rest[taken..];
		}
		else
		{
			usz? h = c.session.pump();
			if (catch f = h)
			{
				self.drop(c);
				return;
			}
			handled = h;
		}
		char[] out = c.session.output();
		usz wrote = out.len;
		if (wrote > 0)
		{
			if (catch f = c.io.write(out, self.write_timeout))
			{
				self.drop(c);
				return;
			}
			c.session.consume_output(wrote);
		}
		bool progress = taken > 0 || handled > 0 || wrote > 0;
		if (rest.len == 0 && !progress) return;
		if (rest.len > 0 && !progress)
		{
			self.drop(c);                    // bytes nobody can take: a broken peer
			return;
		}
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
		polls[n] = { .socket = c.io.socket.sock, .events = PollSubscribe.READ };
		owner[n] = (usz)i;
		n++;
	}
	ulong ready = net::poll(polls[:n], sanitize(timeout))!;
	if (ready == 0) return;
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
				slot.used = true;
			}
			else
			{
				TcpSocket dropped = accepted;
				(void)dropped.close();
			}
		}
	}
	for (usz k = 1; k < n; k++)
	{
		if ((ushort)polls[k].revents == 0) continue;
		TcpConn* c = &self.conns[owner[k]];
		if (c.used) self.service(c);
	}
}

// Serves until *stop becomes true (checked every 100 ms).
fn void? TcpServer.serve(&self, bool* stop)
{
	while (!*stop) self.serve_once(time::ms(100))!;
}
