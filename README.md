# modbus.c3l

Modbus library for C3: a sans-IO protocol core (PDU codec, MBAP and RTU framing, client and server state
machines), with a blocking TCP adapter and a small CLI planned on top.

Status: early. Implemented so far: constants, faults, CRC-16, MBAP framing (stream reassembly) and RTU framing.

Writes to machines are explicit: the client refuses write functions unless `allow_write` is set, and the CLI
needs `--allow-write`.

Licence: MIT.
