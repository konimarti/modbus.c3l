import argparse
import logging
import sys
import warnings

warnings.filterwarnings("ignore")
logging.getLogger("pymodbus").setLevel(logging.ERROR)

from pymodbus.client import ModbusTcpClient


def report_ok(name):
    print(f"OK {name}", flush=True)


def report_fail(name, detail):
    print(f"FAIL {name} {detail}", flush=True)
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Pymodbus TCP peer client")
    parser.add_argument("--host", default="127.0.0.1", help="Target host")
    parser.add_argument("--port", type=int, default=5020, help="Target port")
    args = parser.parse_args()

    client = ModbusTcpClient(args.host, port=args.port)
    if not client.connect():
        print(f"FAIL connect unable to connect to {args.host}:{args.port}", flush=True)
        sys.exit(1)

    try:
        # 1. FC 1: Read Coils
        name = "fc1_read_coils"
        r1 = client.read_coils(0, count=10, device_id=1)
        if r1.isError():
            report_fail(name, f"response error: {r1}")
        want = [(i % 3 == 0) for i in range(10)]
        if r1.bits[:10] != want:
            report_fail(name, f"got {r1.bits[:10]}, want {want}")
        report_ok(name)

        # 2. FC 2: Read Discrete Inputs
        name = "fc2_read_discrete_inputs"
        r2 = client.read_discrete_inputs(0, count=10, device_id=1)
        if r2.isError():
            report_fail(name, f"response error: {r2}")
        want = [(i % 2 == 1) for i in range(10)]
        if r2.bits[:10] != want:
            report_fail(name, f"got {r2.bits[:10]}, want {want}")
        report_ok(name)

        # 3. FC 3: Read Holding Registers
        name = "fc3_read_holding_registers"
        r3 = client.read_holding_registers(0, count=5, device_id=1)
        if r3.isError():
            report_fail(name, f"response error: {r3}")
        want = [i * 10 for i in range(5)]
        if r3.registers[:5] != want:
            report_fail(name, f"got {r3.registers[:5]}, want {want}")
        report_ok(name)

        # 4. FC 4: Read Input Registers
        name = "fc4_read_input_registers"
        r4 = client.read_input_registers(0, count=5, device_id=1)
        if r4.isError():
            report_fail(name, f"response error: {r4}")
        want = [i + 1000 for i in range(5)]
        if r4.registers[:5] != want:
            report_fail(name, f"got {r4.registers[:5]}, want {want}")
        report_ok(name)

        # 5. FC 5: Write Single Coil
        name = "fc5_write_single_coil"
        w5 = client.write_coil(50, True, device_id=1)
        if w5.isError():
            report_fail(name, f"write error: {w5}")
        rb5 = client.read_coils(50, count=1, device_id=1)
        if rb5.isError() or not rb5.bits[0]:
            report_fail(name, f"readback failed: {rb5}")
        report_ok(name)

        # 6. FC 6: Write Single Register
        name = "fc6_write_single_register"
        w6 = client.write_register(50, 1234, device_id=1)
        if w6.isError():
            report_fail(name, f"write error: {w6}")
        rb6 = client.read_holding_registers(50, count=1, device_id=1)
        if rb6.isError() or rb6.registers[0] != 1234:
            report_fail(name, f"readback failed: {rb6}")
        report_ok(name)

        # 7. FC 15: Write Multiple Coils
        name = "fc15_write_multiple_coils"
        w15 = client.write_coils(60, [True, False, True], device_id=1)
        if w15.isError():
            report_fail(name, f"write error: {w15}")
        rb15 = client.read_coils(60, count=3, device_id=1)
        if rb15.isError() or rb15.bits[:3] != [True, False, True]:
            report_fail(name, f"readback failed: {rb15}")
        report_ok(name)

        # 8. FC 16: Write Multiple Registers
        name = "fc16_write_multiple_registers"
        w16 = client.write_registers(60, [99, 100, 101], device_id=1)
        if w16.isError():
            report_fail(name, f"write error: {w16}")
        rb16 = client.read_holding_registers(60, count=3, device_id=1)
        if rb16.isError() or rb16.registers[:3] != [99, 100, 101]:
            report_fail(name, f"readback failed: {rb16}")
        report_ok(name)

        # 9. FC 22: Mask Write Register
        name = "fc22_mask_write_register"
        client.write_register(70, 0x1234, device_id=1)
        w22 = client.mask_write_register(address=70, and_mask=0xFF00, or_mask=0x0055, device_id=1)
        if w22.isError():
            report_fail(name, f"mask write error: {w22}")
        rb22 = client.read_holding_registers(70, count=1, device_id=1)
        if rb22.isError() or rb22.registers[0] != 0x1255:
            report_fail(name, f"readback failed: got {hex(rb22.registers[0]) if not rb22.isError() else rb22}, want 0x1255")
        report_ok(name)

        # 10. FC 23: Read/Write Multiple Registers
        name = "fc23_read_write_registers"
        rw23 = client.readwrite_registers(read_address=10, read_count=2, write_address=80, values=[777, 888], device_id=1)
        if rw23.isError():
            report_fail(name, f"readwrite error: {rw23}")
        if rw23.registers[:2] != [100, 110]:
            report_fail(name, f"readback part failed: got {rw23.registers[:2]}, want [100, 110]")
        rb23 = client.read_holding_registers(80, count=2, device_id=1)
        if rb23.isError() or rb23.registers[:2] != [777, 888]:
            report_fail(name, f"written registers readback failed: {rb23}")
        report_ok(name)

        # 11. FC 43/14: Read Device Identification
        name = "fc43_read_device_id"
        r43 = client.read_device_information(read_code=1, object_id=0, device_id=1)
        if r43.isError():
            report_fail(name, f"device info error: {r43}")
        info = getattr(r43, "information", {})
        vendor = info.get(0, b"")
        if isinstance(vendor, bytes):
            vendor = vendor.decode("latin1", errors="ignore")
        if "ACME" not in vendor:
            report_fail(name, f"vendor got {vendor}, want ACME")
        report_ok(name)

        # 12. FC 8/0: Diagnostics Return Query Data
        name = "fc8_diagnostics_query"
        payload = b"\x12\x34"
        r8 = client.diag_query_data(payload, device_id=1)
        if r8.isError():
            report_fail(name, f"diagnostics error: {r8}")
        echoed = getattr(r8, "message", None)
        if echoed != payload:
            report_fail(name, f"echo got {echoed}, want {payload}")
        report_ok(name)

    finally:
        client.close()


if __name__ == "__main__":
    main()
