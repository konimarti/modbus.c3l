module main;

import std::core::mem;
import std::io;
import std::net;
import std::time;
import modbus;
import modbus::pdu;
import modbus::server;
import modbus::rtu_stream;
import modbus::tcp;
import modbus::transport;

fn int run(String host, ushort port)
{
	RegisterMap map;
	if (catch f = map.init(mem, 100, 100, 100, 100))
	{
		io::printfn("FAIL init map");
		return 1;
	}
	defer map.free();

	for (usz i = 0; i < 100; i++)
	{
		map.holding[i] = (ushort)(i * 10);
		map.input[i] = (ushort)(i + 1000);
		map.coils[i] = (i % 3 == 0);
		map.discrete[i] = (i % 2 == 1);
	}

	pdu::DeviceObject[9] objs = {
		{ .id = 0, .value = "ACME" },
		{ .id = 1, .value = "X1" },
		{ .id = 2, .value = "1.0" },
		{ .id = 3, .value = "http://acme.example" },
		{ .id = 4, .value = "Modbus Device" },
		{ .id = 5, .value = "M1" },
		{ .id = 6, .value = "App1" },
		{ .id = 0x80, .value = "Ext0x80" },
		{ .id = 0x81, .value = "Ext0x81" }
	};

	ServerConfig cfg;
	cfg.accept_any_unit = true;
	cfg.allow_diagnostics = true;
	cfg.conformity_level = 0x83;
	cfg.device_objects = &objs;

	TcpServerSocket? l = tcp::listen(host, port, 8, SocketOption.REUSEADDR);
	if (catch f = l)
	{
		io::printfn("FAIL listen on %s:%d", host, port);
		return 1;
	}
	TcpServerSocket listener = l;

$if $feat(RTU):
	// RTU framing, one TCP connection at a time (a port probe connects and leaves, then the real client comes):
	// frames end after 20 ms of silence
	for (int c = 0; c < 8; c++)
	{
		TcpSocket? conn = tcp::accept(&listener);
		if (catch f = conn) break;
		TcpTransport io;
		io.adopt(conn);
		RtuStream stream;
		stream.init((Transport)&io, time::ms(20));
		for (int i = 0; i < 600; i++)
		{
			if (catch f = rtu_stream::serve_rtu_once(&stream, &cfg, (DataModel)&map, time::ms(100))) break;
		}
		(void)io.close();
	}
	(void)listener.close();
	return 0;
$else
	TcpServer server;
	if (catch f = server.init(listener, &cfg, (DataModel)&map, mem))
	{
		io::printfn("FAIL init server");
		(void)listener.close();
		return 1;
	}
	defer server.close();

	// Serve requests. Cap total run time at 60s so it doesn't linger if orphaned.
	for (int i = 0; i < 600; i++)
	{
		(void)server.serve_once(time::ms(100));
	}

	return 0;
$endif
}

fn int main(String[] args)
{
	String host = "127.0.0.1";
	ushort port = 5020;
	if (args.len > 1) host = args[1];
	if (args.len > 2)
	{
		ulong? p = args[2].to_ulong();
		if (try val = p) port = (ushort)val;
	}
	return run(host, port);
}
