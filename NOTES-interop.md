# Pymodbus Interoperability Notes and Verification

This document records findings from interoperability testing between `modbus.c3l` and `pymodbus` (v3.16.2 on Python 3.14), settling the **verify** items from `DESIGN.md` and `M9.md`.

---

## 1. Environment & Setup

- **Python Version**: Python 3.14.0rc1 / 3.14+ in virtual environment `.work/peer/venv/`.
- **Pymodbus Version**: Pymodbus 3.16.2.
- **Verification**: Pymodbus runs cleanly under Python 3.14 offline without runtime issues or deprecated standard library breakage.
- **Test Execution**: Both directions (C3 client -> Pymodbus server, and Pymodbus client -> C3 server) pass all 12 tested function codes (FC 1, 2, 3, 4, 5, 6, 15, 16, 22, 23, 43/14, 8/0).

---

## 2. Settled Design Verification Items

### 2.1 64-bit CDAB Word Order
- **Question**: How does pymodbus word order option align with 32-bit and 64-bit register endianness conventions (ABCD, CDAB, BADC, DCBA)?
- **Finding**:
  - In pymodbus, `BinaryPayloadDecoder.fromRegisters(registers, byteorder=Endian.BIG, wordorder=Endian.LITTLE)` (or `convert_from_registers(..., word_order="little")`) reverses the sequence of 16-bit words.
  - For a 64-bit integer across 4 registers `[r0, r1, r2, r3]`, little word order treats `r0` as the least significant 16-bit word and `r3` as the most significant 16-bit word.
  - With standard big-endian byte order inside each 16-bit word (`AB`, `CD`, `EF`, `GH`), the byte stream is `GH EF CD AB`.
  - In `modbus.c3l`, `Order.CDAB` defines word reversal: for 32-bit values it swaps the two words (`[w1, w0]`), and for 64-bit values it reverses all four words (`[w3, w2, w1, w0]`).
  - **Settled**: `Order.CDAB` in `modbus.c3l` corresponds exactly to pymodbus's `wordorder=Endian.LITTLE` (or `word_order="little"`).

### 2.2 FC 8 (Diagnostics) Sub-function Error Handling
- **Question**: When a client requests an unsupported diagnostic sub-function, or provides an invalid payload length, what exception code is returned?
- **Finding**:
  - Sub-function `0x0000` (Return Query Data): echoes payload data unmodified. Payload must be a multiple of 2 bytes with at least 2 bytes (MAP 6.8). An odd or empty payload returns exception `0x03` (`ILLEGAL_DATA_VALUE`).
  - Unsupported sub-functions (e.g. `0x0001`, `0x0004`): both pymodbus and `modbus.c3l` return exception `0x01` (`ILLEGAL_FUNCTION`).
  - **Settled**: Sub-function `0x0000` is echoed; any unsupported diagnostic sub-function returns exception `0x01`.

### 2.3 FC 43 / MEI Type 14 (Read Device Identification)
- **Question**: Can pymodbus serve FC 43/14? What happens on unknown MEI codes and unknown start object IDs?
- **Finding**:
  - **Serving FC 43/14**: Pymodbus serves FC 43/14 via `ModbusDeviceIdentification(info={...})`. It supports basic objects (0..2: VendorName, ProductCode, MajorMinorRevision), regular objects (3..6), and extended objects (0x80..0xFF).
  - **Unknown MEI Code**: If a request specifies FC 43 with an unknown MEI type (e.g. `0x0D` instead of `0x0E`), pymodbus and `modbus.c3l` return exception `0x01` (`ILLEGAL_FUNCTION`).
  - **Stream Access (Read Device ID codes 1, 2, 3) with Unknown Start ID**: When stream reading starts at an ID that does not exist or is past the highest ID, pymodbus returns a response with `number of objects = 0` (or wraps), rather than raising an exception. `modbus.c3l` follows the same stream rule (returning available objects or 0 objects without exception).
  - **Individual Access (Read Device ID code 4) with Unknown ID**: When requesting a specific non-existent object ID, both pymodbus and `modbus.c3l` return exception `0x02` (`ILLEGAL_DATA_ADDRESS`).
  - **Continuation & PDU limit**: Objects exceeding the 253-byte PDU limit are split across consecutive responses using `more_follows` and `next_object_id`.

### 2.4 FC 0 and Exception Frame Handling (Q12)
- **Question**: How are FC 0 and function codes with high bit set (FC >= 0x80) handled?
- **Finding**:
  - **FC 0**: Function code 0 is invalid. Pymodbus and `modbus.c3l` return exception `0x01` (`ILLEGAL_FUNCTION`), producing the error PDU `80 01`.
  - **FC >= 0x80**: A frame where the function code has bit 7 set represents an exception response, not a request. Answering an incoming frame with FC >= 0x80 would create an exception response to an exception response. Both pymodbus and `modbus.c3l` drop frames with FC >= 0x80 silently without transmitting an answer.

### 2.5 Read-Only Write Handling (Q6)
- **Question**: What exception code is returned when a client attempts to write to a read-only address or read-only data model?
- **Finding**:
  - Pymodbus datastores return `0x02` (`ILLEGAL_DATA_ADDRESS`) when an address has no registered writable block.
  - In `modbus.c3l`, `RegisterMap.read_only = true` answers any write function code (FC 5, 6, 15, 16, 22, 23) with exception `0x01` (`ILLEGAL_FUNCTION`), explicitly signaling that write operations are not supported by the device. An unmapped address out of range returns `0x02` (`ILLEGAL_DATA_ADDRESS`).
  - **Settled**: `0x01` (`ILLEGAL_FUNCTION`) for writes when read-only mode is active; `0x02` (`ILLEGAL_DATA_ADDRESS`) for unmapped / out-of-range addresses.

### 2.6 RTU Framing over TCP Socket
- **Question**: Does pymodbus support RTU framing over TCP connections (for M10 gateway testing)?
- **Finding**:
  - Yes. Pymodbus provides `FramerType.RTU` in `pymodbus.framer`.
  - Passing `framer=FramerType.RTU` to `ModbusTcpClient(..., framer=FramerType.RTU)` or `StartTcpServer(..., framer=FramerType.RTU)` enables serial RTU framing (including CRC16 validation) over standard stream TCP sockets.
  - **Settled**: Pymodbus RTU-over-TCP is fully supported and available for gateway validation in M10.

---

## 3. Interoperability & Lenient Peer Observations

1. **Unit ID Default**: In TCP mode, unit ID / slave ID defaults to 1 (unit ID 0 is broadcast, unit ID 255 is often used by simple gateways). In pymodbus 3.16+, the client API uses the parameter name `device_id` (previously `slave`).
2. **Sequential Data Block Offsets**: Pymodbus's `ModbusSequentialDataBlock(address, values)` treats the `address` parameter as 1-based internally (decrementing by 1 to compute 0-based protocol wire addresses). To seed protocol wire address 0, `ModbusSequentialDataBlock(1, values)` must be passed.
3. **Keyword-Only Parameters in Pymodbus 3.x**: Pymodbus 3.16+ enforces keyword arguments for count, device_id, etc. (e.g. `client.read_holding_registers(0, count=5, device_id=1)`).
4. **FC 22 Mask Write Register**: Pymodbus parameter names are `address`, `and_mask`, and `or_mask`. The formula `(current & and_mask) | (or_mask & ~and_mask)` is applied identically by both implementations.
5. **FC 23 Read/Write Registers**: Pymodbus parameter names are `read_address`, `read_count`, `write_address`, `values`. The write operation occurs before the read operation, so if the read range overlaps the written registers, the new values are read back.
