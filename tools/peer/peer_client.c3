module main;

import std::core::mem;
import std::io;
import std::time;
import modbus;
import modbus::client;
import modbus::pdu;
import modbus::tcp;
import modbus::transport;

fn void report_ok(String name)
{
	io::printfn("OK %s", name);
}

fn void report_fail(String name, String detail)
{
	io::printfn("FAIL %s %s", name, detail);
}

fn int run(String host, ushort port)
{
	TcpTransport transport;
	if (catch f = transport.connect(host, port, time::sec(3)))
	{
		report_fail("connect", "unable to connect");
		return 1;
	}
	defer (void)transport.close();

	ClientConfig config = client::default_config();
	config.allow_write = true;
	config.timeout = time::sec(3);

	BlockingClient bc;
	if (catch f = bc.init((Transport)&transport, config, mem))
	{
		report_fail("init", "failed to init client");
		return 1;
	}
	defer bc.free();

	ExceptionCode exc;

	// 1. FC 1: Read Coils
	{
		String name = "fc1_read_coils";
		Request r = pdu::read_request(Fc.READ_COILS, 0, 10);
		Response? rsp = bc.call(&r, &exc);
		if (catch f = rsp)
		{
			report_fail(name, "call failed");
			return 1;
		}
		for (usz i = 0; i < 10; i++)
		{
			bool want = (i % 3 == 0);
			if (rsp.coil(i) != want)
			{
				report_fail(name, "data mismatch");
				return 1;
			}
		}
		report_ok(name);
	}

	// 2. FC 2: Read Discrete Inputs
	{
		String name = "fc2_read_discrete_inputs";
		Request r = pdu::read_request(Fc.READ_DISCRETE_INPUTS, 0, 10);
		Response? rsp = bc.call(&r, &exc);
		if (catch f = rsp)
		{
			report_fail(name, "call failed");
			return 1;
		}
		for (usz i = 0; i < 10; i++)
		{
			bool want = (i % 2 == 1);
			if (rsp.coil(i) != want)
			{
				report_fail(name, "data mismatch");
				return 1;
			}
		}
		report_ok(name);
	}

	// 3. FC 3: Read Holding Registers
	{
		String name = "fc3_read_holding_registers";
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 0, 5);
		Response? rsp = bc.call(&r, &exc);
		if (catch f = rsp)
		{
			report_fail(name, "call failed");
			return 1;
		}
		for (usz i = 0; i < 5; i++)
		{
			ushort want = (ushort)(i * 10);
			if (rsp.reg(i) != want)
			{
				report_fail(name, "data mismatch");
				return 1;
			}
		}
		report_ok(name);
	}

	// 4. FC 4: Read Input Registers
	{
		String name = "fc4_read_input_registers";
		Request r = pdu::read_request(Fc.READ_INPUT_REGISTERS, 0, 5);
		Response? rsp = bc.call(&r, &exc);
		if (catch f = rsp)
		{
			report_fail(name, "call failed");
			return 1;
		}
		for (usz i = 0; i < 5; i++)
		{
			ushort want = (ushort)(i + 1000);
			if (rsp.reg(i) != want)
			{
				report_fail(name, "data mismatch");
				return 1;
			}
		}
		report_ok(name);
	}

	// 5. FC 5: Write Single Coil
	{
		String name = "fc5_write_single_coil";
		Request w = pdu::write_single_coil(50, true);
		Response? wrsp = bc.call(&w, &exc);
		if (catch f = wrsp)
		{
			report_fail(name, "write failed");
			return 1;
		}
		Request r = pdu::read_request(Fc.READ_COILS, 50, 1);
		Response? rrsp = bc.call(&r, &exc);
		if (catch f = rrsp)
		{
			report_fail(name, "readback failed");
			return 1;
		}
		if (!rrsp.coil(0))
		{
			report_fail(name, "readback value mismatch");
			return 1;
		}
		report_ok(name);
	}

	// 6. FC 6: Write Single Register
	{
		String name = "fc6_write_single_register";
		Request w = pdu::write_single_register(50, 1234);
		Response? wrsp = bc.call(&w, &exc);
		if (catch f = wrsp)
		{
			report_fail(name, "write failed");
			return 1;
		}
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 50, 1);
		Response? rrsp = bc.call(&r, &exc);
		if (catch f = rrsp)
		{
			report_fail(name, "readback failed");
			return 1;
		}
		if (rrsp.reg(0) != 1234)
		{
			report_fail(name, "readback failed");
			return 1;
		}
		report_ok(name);
	}

	// 7. FC 15: Write Multiple Coils
	{
		String name = "fc15_write_multiple_coils";
		bool[3] coils = { true, false, true };
		char[16] scratch;
		Request? w = pdu::write_multiple_coils(60, &coils, &scratch);
		if (catch f = w)
		{
			report_fail(name, "builder failed");
			return 1;
		}
		Response? wrsp = bc.call(&w, &exc);
		if (catch f = wrsp)
		{
			report_fail(name, "write failed");
			return 1;
		}
		Request r = pdu::read_request(Fc.READ_COILS, 60, 3);
		Response? rrsp = bc.call(&r, &exc);
		if (catch f = rrsp)
		{
			report_fail(name, "readback failed");
			return 1;
		}
		if (!rrsp.coil(0) || rrsp.coil(1) || !rrsp.coil(2))
		{
			report_fail(name, "readback failed");
			return 1;
		}
		report_ok(name);
	}

	// 8. FC 16: Write Multiple Registers
	{
		String name = "fc16_write_multiple_registers";
		ushort[3] regs = { 99, 100, 101 };
		char[16] scratch;
		Request? w = pdu::write_multiple_registers(60, &regs, &scratch);
		if (catch f = w)
		{
			report_fail(name, "builder failed");
			return 1;
		}
		Response? wrsp = bc.call(&w, &exc);
		if (catch f = wrsp)
		{
			report_fail(name, "write failed");
			return 1;
		}
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 60, 3);
		Response? rrsp = bc.call(&r, &exc);
		if (catch f = rrsp)
		{
			report_fail(name, "readback failed");
			return 1;
		}
		if (rrsp.reg(0) != 99 || rrsp.reg(1) != 100 || rrsp.reg(2) != 101)
		{
			report_fail(name, "readback failed");
			return 1;
		}
		report_ok(name);
	}

	// 9. FC 22: Mask Write Register
	{
		String name = "fc22_mask_write_register";
		Request init_reg = pdu::write_single_register(70, 0x1234);
		if (catch f = bc.call(&init_reg, &exc))
		{
			report_fail(name, "init write failed");
			return 1;
		}
		Request w = pdu::mask_write_register(70, 0xFF00, 0x0055);
		Response? wrsp = bc.call(&w, &exc);
		if (catch f = wrsp)
		{
			report_fail(name, "mask write failed");
			return 1;
		}
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 70, 1);
		Response? rrsp = bc.call(&r, &exc);
		if (catch f = rrsp)
		{
			report_fail(name, "readback failed");
			return 1;
		}
		if (rrsp.reg(0) != 0x1255)
		{
			report_fail(name, "readback failed");
			return 1;
		}
		report_ok(name);
	}

	// 10. FC 23: Read/Write Multiple Registers
	{
		String name = "fc23_read_write_registers";
		ushort[2] write_vals = { 777, 888 };
		char[16] scratch;
		Request? rw = pdu::read_write_registers(10, 2, 80, &write_vals, &scratch);
		if (catch f = rw)
		{
			report_fail(name, "builder failed");
			return 1;
		}
		Response? rwrsp = bc.call(&rw, &exc);
		if (catch f = rwrsp)
		{
			report_fail(name, "rw call failed");
			return 1;
		}
		if (rwrsp.reg(0) != 100 || rwrsp.reg(1) != 110)
		{
			report_fail(name, "rw call data mismatch");
			return 1;
		}
		Request r = pdu::read_request(Fc.READ_HOLDING_REGISTERS, 80, 2);
		Response? rrsp = bc.call(&r, &exc);
		if (catch f = rrsp)
		{
			report_fail(name, "readback failed");
			return 1;
		}
		if (rrsp.reg(0) != 777 || rrsp.reg(1) != 888)
		{
			report_fail(name, "readback failed");
			return 1;
		}
		report_ok(name);
	}

	// 11. FC 43/14: Read Device Identification
	{
		String name = "fc43_read_device_id";
		Request r = pdu::read_device_id(1, 0);
		Response? rsp = bc.call(&r, &exc);
		if (catch f = rsp)
		{
			report_fail(name, "call failed");
			return 1;
		}
		ObjectIter it = pdu::objects(&rsp);
		DeviceObject obj;
		bool found_vendor = false;
		while (it.next(&obj) ?? false)
		{
			if (obj.id == 0 && obj.value == "ACME") found_vendor = true;
		}
		if (!found_vendor)
		{
			report_fail(name, "vendor object not found or not ACME");
			return 1;
		}
		report_ok(name);
	}

	// 12. FC 8/0: Diagnostics Return Query Data
	{
		String name = "fc8_diagnostics_query";
		char[2] payload = { (char)0x12, (char)0x34 };
		Request r = { .fc = (char)Fc.DIAGNOSTICS, .sub = 0x0000, .data = &payload };
		Response? rsp = bc.call(&r, &exc);
		if (catch f = rsp)
		{
			report_fail(name, "call failed");
			return 1;
		}
		if (rsp.sub != 0x0000 || rsp.data.len != 2 || rsp.data[0] != (char)0x12 || rsp.data[1] != (char)0x34)
		{
			report_fail(name, "echo mismatch");
			return 1;
		}
		report_ok(name);
	}

	return 0;
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
