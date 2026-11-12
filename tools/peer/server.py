import argparse
import logging
import os
import signal
import sys
import warnings

warnings.filterwarnings("ignore")
logging.getLogger("pymodbus").setLevel(logging.ERROR)

import pymodbus.datastore as ds
import pymodbus.pdu.device as pdu_device
from pymodbus import FramerType
from pymodbus.server import StartTcpServer, ServerStop


def main():
    parser = argparse.ArgumentParser(description="Pymodbus TCP peer server")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address")
    parser.add_argument("--port", type=int, default=5020, help="Bind port")
    parser.add_argument("--rtu", action="store_true", help="RTU framing over the TCP connection")
    args = parser.parse_args()

    hr_vals = [i * 10 for i in range(100)]
    ir_vals = [i + 1000 for i in range(100)]
    co_vals = [(i % 3 == 0) for i in range(100)]
    di_vals = [(i % 2 == 1) for i in range(100)]

    # Note: ModbusSequentialDataBlock(1, ...) maps to protocol address 0 (1 - 1 = 0)
    store = ds.ModbusDeviceContext(
        hr=ds.ModbusSequentialDataBlock(1, hr_vals),
        ir=ds.ModbusSequentialDataBlock(1, ir_vals),
        co=ds.ModbusSequentialDataBlock(1, co_vals),
        di=ds.ModbusSequentialDataBlock(1, di_vals),
    )
    context = ds.ModbusServerContext(devices={1: store}, single=False)

    identity = pdu_device.ModbusDeviceIdentification(info={
        0x00: "ACME",
        0x01: "X1",
        0x02: "1.0",
        0x03: "http://acme.example",
        0x04: "Modbus Device",
        0x05: "M1",
        0x06: "App1",
        0x80: "Ext0x80",
        0x81: "Ext0x81",
    })

    def handle_sig(sig, frame):
        try:
            ServerStop()
        except Exception:
            pass
        os._exit(0)

    signal.signal(signal.SIGINT, handle_sig)
    signal.signal(signal.SIGTERM, handle_sig)

    StartTcpServer(
        context=context,
        identity=identity,
        address=(args.host, args.port),
        framer=FramerType.RTU if args.rtu else FramerType.SOCKET,
    )


if __name__ == "__main__":
    main()
