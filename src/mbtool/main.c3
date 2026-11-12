module mbtool;

import std::core::mem;
import std::io;
import std::net;
import std::time;
import modbus;
import modbus::client;
import modbus::data;
import modbus::pdu;
import modbus::server;
import modbus::tcp;
import modbus::transport;

const String USAGE = `usage: mbtool <command> [options]

Read and write Modbus TCP devices, or serve a register map. Addresses are 0-based protocol addresses.

commands:
  read  HOST[:PORT] [--unit N] [--fc coils|discrete|holding|input] [--addr A] [--count C]
                    [--as u16|i16|u32|i32|f32|u64|i64|f64] [--order ABCD|CDAB|BADC|DCBA] [--timeout MS]
        print the values on one line, separated by spaces (default: holding registers as u16)
  write HOST[:PORT] --allow-write [--unit N] [--fc coil|register|coils|registers] [--addr A] VALUE...
        write coils (0 or 1) or registers; refused without --allow-write (nothing is sent)
  serve [--bind ADDR] [--port P] [--unit N] [--coils N] [--registers N] [--allow-write]
        serve an in-memory register map (default 127.0.0.1:502, read-only without --allow-write)
  devid HOST[:PORT] [--unit N] [--code 1|2|3]
        read the device identification, one "id: value" line per object

options:
  -h, --help   show this help message

exit codes: 0 ok, 1 error or timeout, 2 usage error or refused write, 3 Modbus exception from the device
`;

struct Opts
{
	String cmd;
	String host;
	int port;
	int unit;
	bool unit_given;
	String fc;
	int addr;
	int count;
	String as_type;
	String order;
	int timeout_ms;
	String bind;
	int coils;
	int registers;
	int code;
	bool allow_write;
	bool help;
	String[] values;
}

fn int usage_error(String msg)
{
	io::eprintfn("mbtool: %s", msg);
	io::eprintn("try: mbtool -h");
	return 2;
}

fn long? parse_num(String s)
{
	if (s.len > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) return s[2..].to_long(16);
	return s.to_long();
}

// HOST or HOST:PORT (IPv6 literals are not supported).
fn void split_host(String arg, Opts* o)
{
	sz? colon = arg.rindex_of_char(':');
	if (try c = colon)
	{
		o.host = arg[:c];
		long? p = arg[c + 1..].to_long();
		o.port = -1;
		if (try v = p) o.port = (int)v;
	}
	else
	{
		o.host = arg;
	}
}

// Fills Opts from the arguments. A message is returned in `err` when something is wrong.
fn bool parse_args(String[] args, Opts* o, String* err)
{
	o.port = -2;
	o.unit = 1;
	o.fc = "";
	o.count = 1;
	o.timeout_ms = 2000;
	o.bind = "127.0.0.1";
	o.coils = 1000;
	o.registers = 1000;
	o.code = 1;
	o.order = "ABCD";
	String[] values = mem::temp_array(String, (sz)args.len);
	usz nvalues = 0;
	if (args.len < 2)
	{
		*err = "no command given";
		return false;
	}
	o.cmd = args[1];
	for (usz i = 1; i < args.len; i++)
	{
		String a = args[i];
		if (a == "-h" || a == "--help")
		{
			o.help = true;
			continue;
		}
		if (i == 1) continue;                      // the command
		if (a == "--allow-write")
		{
			o.allow_write = true;
			continue;
		}
		if (a.len > 2 && a[0] == '-' && a[1] == '-')
		{
			if (i + 1 >= args.len)
			{
				*err = string::tformat("option %s needs a value", a);
				return false;
			}
			String v = args[++i];
			long? n = parse_num(v);
			switch (a)
			{
				case "--fc": o.fc = v;
				case "--as": o.as_type = v;
				case "--order": o.order = v;
				case "--bind": o.bind = v;
				case "--unit":
					if (catch n) { *err = string::tformat("bad number for --unit: %s", v); return false; }
					o.unit = (int)n;
					o.unit_given = true;
				case "--addr":
				case "--count":
				case "--port":
				case "--coils":
				case "--registers":
				case "--timeout":
				case "--code":
					if (catch n) { *err = string::tformat("bad number for %s: %s", a, v); return false; }
					switch (a)
					{
						case "--addr": o.addr = (int)n;
						case "--count": o.count = (int)n;
						case "--port": o.port = (int)n;
						case "--coils": o.coils = (int)n;
						case "--registers": o.registers = (int)n;
						case "--timeout": o.timeout_ms = (int)n;
						default: o.code = (int)n;
					}
				default:
					*err = string::tformat("unknown option %s", a);
					return false;
			}
			continue;
		}
		if (o.cmd != "serve" && o.host.len == 0)
		{
			split_host(a, o);
			continue;
		}
		values[nvalues++] = a;
	}
	o.values = values[:nvalues];
	return true;
}

fn String exception_name(ExceptionCode c)
{
	switch (c)
	{
		case ILLEGAL_FUNCTION: return "illegal function";
		case ILLEGAL_DATA_ADDRESS: return "illegal data address";
		case ILLEGAL_DATA_VALUE: return "illegal data value";
		case SERVER_DEVICE_FAILURE: return "server device failure";
		case ACKNOWLEDGE: return "acknowledge";
		case SERVER_DEVICE_BUSY: return "server device busy";
		case MEMORY_PARITY_ERROR: return "memory parity error";
		case GATEWAY_PATH_UNAVAILABLE: return "gateway path unavailable";
		case GATEWAY_TARGET_NO_RESPONSE: return "gateway target failed to respond";
		default: return "unknown exception";
	}
}

// Exit code of a failed call: 3 for a Modbus exception, 2 for the write guard, 1 for everything else.
fn int report(fault f, ExceptionCode exc)
{
	if (f == modbus::REMOTE_EXCEPTION)
	{
		io::eprintfn("exception: %s (0x%02x)", exception_name(exc), (char)exc);
		return 3;
	}
	if (f == modbus::WRITE_NOT_ALLOWED)
	{
		io::eprintn("refusing to write: pass --allow-write");
		return 2;
	}
	if (f == modbus::TIMEOUT)
	{
		io::eprintn("error: no answer (timeout)");
		return 1;
	}
	io::eprintfn("error: %s", f);
	return 1;
}

// Connects and prepares a blocking client. Returns 0 or an exit code.
fn int open_client(Opts* o, TcpTransport* t, BlockingClient* bc)
{
	if (o.host.len == 0) return usage_error("no HOST given");
	int port = o.port == -2 ? 502 : o.port;
	if (port < 1 || port > 65535) return usage_error("bad port");
	if (o.unit < 0 || o.unit > 255) return usage_error("--unit must be 0 to 255");
	if (o.timeout_ms < 1) return usage_error("--timeout must be at least 1 ms");
	if (catch f = t.connect(o.host, (ushort)port, time::ms(o.timeout_ms)))
	{
		io::eprintfn("error: cannot connect to %s:%d (%s)", o.host, port, f);
		return 1;
	}
	ClientConfig k = client::default_config();
	k.unit = (char)o.unit;
	k.timeout = time::ms(o.timeout_ms);
	k.allow_write = o.allow_write;
	if (catch f = bc.init((Transport)t, k, mem))
	{
		io::eprintfn("error: %s", f);
		return 1;
	}
	return 0;
}

fn bool parse_order(String s, data::Order* out)
{
	switch (s)
	{
		case "ABCD": *out = ABCD;
		case "CDAB": *out = CDAB;
		case "BADC": *out = BADC;
		case "DCBA": *out = DCBA;
		default: return false;
	}
	return true;
}

// ---- read ----

fn int cmd_read(Opts* o)
{
	String fcname = o.fc.len == 0 ? "holding" : o.fc;
	Fc fc;
	bool bits;
	switch (fcname)
	{
		case "coils": fc = READ_COILS; bits = true;
		case "discrete": fc = READ_DISCRETE_INPUTS; bits = true;
		case "holding": fc = READ_HOLDING_REGISTERS;
		case "input": fc = READ_INPUT_REGISTERS;
		default: return usage_error("--fc must be coils, discrete, holding or input");
	}
	if (o.count < 1 || o.addr < 0 || o.addr + o.count > 0x10000) return usage_error("bad --addr or --count");
	usz per = 1;
	String as_type = o.as_type;
	if (as_type.len > 0)
	{
		if (bits) return usage_error("--as only applies to registers");
		switch (as_type)
		{
			case "u16": case "i16": per = 1;
			case "u32": case "i32": case "f32": per = 2;
			case "u64": case "i64": case "f64": per = 4;
			default: return usage_error("--as must be u16, i16, u32, i32, f32, u64, i64 or f64");
		}
		if ((usz)o.count % per != 0) return usage_error("--count must be a multiple of the register size of the type");
	}
	data::Order order;
	if (!parse_order(o.order, &order)) return usage_error("--order must be ABCD, CDAB, BADC or DCBA");

	TcpTransport t;
	BlockingClient bc;
	int rc = open_client(o, &t, &bc);
	if (rc != 0) return rc;
	defer
	{
		bc.free();
		(void)t.close();
	}
	usz total = (usz)o.count;
	bool[] bit_values = bits ? mem::temp_array(bool, (sz)total) : {};
	ushort[] regs = bits ? {} : mem::temp_array(ushort, (sz)total);
	usz chunk_max = bits ? modbus::MAX_READ_BITS : modbus::MAX_READ_REGS;   // longer reads are split
	usz done = 0;
	while (done < total)
	{
		usz n = total - done < chunk_max ? total - done : chunk_max;
		Request req = pdu::read_request(fc, (ushort)(o.addr + (int)done), (ushort)n);
		ExceptionCode exc;
		Response? rsp = bc.call(&req, &exc);
		if (catch f = rsp) return report(f, exc);
		if (bits)
		{
			if (catch f = rsp.copy_coils(bit_values[done:n])) return report(f, exc);
		}
		else
		{
			if (catch f = rsp.copy_regs(regs[done:n])) return report(f, exc);
		}
		done += n;
	}
	DString line = dstring::temp();
	if (bits)
	{
		foreach (i, b : bit_values)
		{
			if (i > 0) line.append_char(' ');
			line.append_char(b ? '1' : '0');
		}
	}
	else if (as_type.len == 0)
	{
		foreach (i, r : regs)
		{
			if (i > 0) line.append_char(' ');
			line.appendf("%d", r);
		}
	}
	else
	{
		for (usz at = 0; at < total; at += per)
		{
			if (at > 0) line.append_char(' ');
			switch (as_type)
			{
				case "u16": line.appendf("%d", data::get_u16(regs, at, order)!!);
				case "i16": line.appendf("%d", data::get_i16(regs, at, order)!!);
				case "u32": line.appendf("%d", data::get_u32(regs, at, order)!!);
				case "i32": line.appendf("%d", data::get_i32(regs, at, order)!!);
				case "u64": line.appendf("%d", data::get_u64(regs, at, order)!!);
				case "i64": line.appendf("%d", data::get_i64(regs, at, order)!!);
				case "f32": line.appendf("%g", data::get_f32(regs, at, order)!!);
				default: line.appendf("%g", data::get_f64(regs, at, order)!!);
			}
		}
	}
	io::printn(line.str_view());
	return 0;
}

// ---- write ----

fn int cmd_write(Opts* o)
{
	// the guard comes first: nothing is sent, not even a connection is made, without --allow-write
	if (!o.allow_write)
	{
		io::eprintn("refusing to write: pass --allow-write");
		return 2;
	}
	String fcname = o.fc.len == 0 ? "register" : o.fc;
	if (o.values.len == 0) return usage_error("no VALUE given");
	if (o.addr < 0 || o.addr > 0xFFFF) return usage_error("bad --addr");
	char[260] scratch;
	Request req;
	bool[] bits = mem::temp_array(bool, (sz)o.values.len);
	ushort[] regs = mem::temp_array(ushort, (sz)o.values.len);
	switch (fcname)
	{
		case "coil":
		case "coils":
			foreach (i, v : o.values)
			{
				if (v != "0" && v != "1") return usage_error("coil values are 0 or 1");
				bits[i] = v == "1";
			}
			if (fcname == "coil")
			{
				if (o.values.len != 1) return usage_error("--fc coil takes exactly one value");
				req = pdu::write_single_coil((ushort)o.addr, bits[0]);
			}
			else
			{
				Request? r = pdu::write_multiple_coils((ushort)o.addr, bits, &scratch);
				if (catch f = r) return report(f, ExceptionCode.NONE);
				req = r;
			}
		case "register":
		case "registers":
			foreach (i, v : o.values)
			{
				long? n = parse_num(v);
				if (catch n) return usage_error(string::tformat("bad register value: %s", v));
				if (n < -32768 || n > 65535) return usage_error("register values are -32768 to 65535");
				regs[i] = (ushort)(n & 0xFFFF);
			}
			if (fcname == "register")
			{
				if (o.values.len != 1) return usage_error("--fc register takes exactly one value");
				req = pdu::write_single_register((ushort)o.addr, regs[0]);
			}
			else
			{
				Request? r = pdu::write_multiple_registers((ushort)o.addr, regs, &scratch);
				if (catch f = r) return report(f, ExceptionCode.NONE);
				req = r;
			}
		default:
			return usage_error("--fc must be coil, register, coils or registers");
	}
	TcpTransport t;
	BlockingClient bc;
	int rc = open_client(o, &t, &bc);
	if (rc != 0) return rc;
	defer
	{
		bc.free();
		(void)t.close();
	}
	ExceptionCode exc;
	Response? rsp = bc.call(&req, &exc);
	if (catch f = rsp) return report(f, exc);
	io::printn("ok");
	return 0;
}

// ---- devid ----

fn int cmd_devid(Opts* o)
{
	if (o.code < 1 || o.code > 3) return usage_error("--code must be 1, 2 or 3");
	TcpTransport t;
	BlockingClient bc;
	int rc = open_client(o, &t, &bc);
	if (rc != 0) return rc;
	defer
	{
		bc.free();
		(void)t.close();
	}
	pdu::DeviceObject[64] objs;
	char[8192] text;
	usz? n = bc.read_device_id_all((char)o.code, 16, &objs, &text);
	if (catch f = n) return report(f, ExceptionCode.NONE);
	for (usz i = 0; i < n; i++) io::printfn("%d: %s", objs[i].id, objs[i].value);
	return 0;
}

// ---- serve ----

fn int cmd_serve(Opts* o)
{
	if (o.coils < 1 || o.registers < 1 || o.coils > 65536 || o.registers > 65536) return usage_error("--coils and --registers must be 1 to 65536");
	int port = o.port == -2 ? 502 : o.port;
	if (port < 0 || port > 65535) return usage_error("bad port");
	if (o.unit < 0 || o.unit > 255) return usage_error("--unit must be 0 to 255");
	RegisterMap map;
	if (catch f = map.init(mem, (usz)o.coils, (usz)o.coils, (usz)o.registers, (usz)o.registers))
	{
		io::eprintfn("error: %s", f);
		return 1;
	}
	defer map.free();
	map.read_only = !o.allow_write;
	char[1] units = { (char)o.unit };
	char[8] sid = { 0x01, 0xFF, 'm', 'b', 't', 'o', 'o', 'l' };
	pdu::DeviceObject[3] objs = { { 0, "mbtool" }, { 1, "modbus.c3l" }, { 2, modbus::VERSION } };
	ServerConfig cfg = {
		.accept_any_unit = !o.unit_given,
		.units = o.unit_given ? units[:1] : {},
		.device_objects = &objs,
		.conformity_level = 0x81,
		.server_id = sid[:8],
		.allow_diagnostics = true,
	};
	TcpServerSocket? l = std::net::tcp::listen(o.bind, port, 8, REUSEADDR);
	if (catch f = l)
	{
		io::eprintfn("error: cannot listen on %s:%d (%s)", o.bind, port, f);
		return 1;
	}
	TcpServer srv;
	if (catch f = srv.init(l, &cfg, (DataModel)&map, mem))
	{
		io::eprintfn("error: %s", f);
		return 1;
	}
	defer srv.close();
	ushort actual = l.local_port()!!;
	io::printfn("listening on %s:%d (%s)", o.bind, actual, o.allow_write ? "read-write" : "read-only");
	(void)io::stdout().flush();
	bool stop = false;
	if (catch f = srv.serve(&stop))
	{
		io::eprintfn("error: %s", f);
		return 1;
	}
	return 0;
}

fn int main(String[] args)
{
	@pool()
	{
		Opts o;
		String err;
		if (!parse_args(args, &o, &err))
		{
			if (args.len >= 2 && (args[1] == "-h" || args[1] == "--help"))
			{
				io::print(USAGE);
				return 0;
			}
			return usage_error(err);
		}
		if (o.help || o.cmd == "-h" || o.cmd == "--help")
		{
			io::print(USAGE);
			return 0;
		}
		switch (o.cmd)
		{
			case "read": return cmd_read(&o);
			case "write": return cmd_write(&o);
			case "serve": return cmd_serve(&o);
			case "devid": return cmd_devid(&o);
			default: return usage_error(string::tformat("unknown command %s", o.cmd));
		}
	};
}
