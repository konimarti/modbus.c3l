module modbus;

import std::time;

// Shared constants, enums and faults of modbus.c3l.
// Spec: Modbus Application Protocol v1.1b3 (MAP), Modbus Messaging on TCP/IP v1.0b (MTCP).

faultdef
	SHORT_FRAME,           // fewer bytes than the smallest legal frame / PDU of this function
	TRUNCATED,             // PDU shorter than its own length or byte-count field says
	BAD_LENGTH,            // MBAP length field outside 2..254, or PDU > 253 bytes
	BAD_BYTE_COUNT,        // byte count does not match quantity
	BAD_QUANTITY,          // quantity outside the limits of the function (MAP 6.x)
	BAD_ADDRESS_RANGE,     // addr + qty > 0x10000
	BAD_VALUE,             // FC 5 value not 0x0000/0xFF00, bad MEI object id, ...
	BAD_PROTOCOL_ID,       // MBAP protocol id != 0 (MTCP 3.1.3)
	BAD_CRC,               // RTU CRC-16 mismatch
	UNSUPPORTED_FUNCTION,  // function code outside the v1 set
	BUFFER_TOO_SMALL,      // output buffer too small for the encoded frame
	MISMATCH,              // response does not match its request (fc, echo, sizes)
	TIMEOUT,               // no response before the deadline (client) / no data (transport)
	TOO_MANY_PENDING,      // pipeline depth reached
	UNKNOWN_TRANSACTION,   // response with a transaction id nobody waits for
	OUTPUT_FULL,           // output buffer cannot take another frame: drain it first
	CLOSED,                // peer closed or transport failed
	WRITE_NOT_ALLOWED,     // write function refused: ClientConfig.allow_write is false
	REMOTE_EXCEPTION,      // blocking call: peer answered with an exception (code in out param)
	SHORT_REGISTERS,       // data helper: not enough registers
	BAD_STRING;            // data helper: string does not fit / is not ASCII

// Function codes (MAP 5, 6, Table 1)
constdef Fc : char
{
	READ_COILS = 0x01,
	READ_DISCRETE_INPUTS = 0x02,
	READ_HOLDING_REGISTERS = 0x03,
	READ_INPUT_REGISTERS = 0x04,
	WRITE_SINGLE_COIL = 0x05,
	WRITE_SINGLE_REGISTER = 0x06,
	DIAGNOSTICS = 0x08,
	WRITE_MULTIPLE_COILS = 0x0F,
	WRITE_MULTIPLE_REGISTERS = 0x10,
	REPORT_SERVER_ID = 0x11,
	MASK_WRITE_REGISTER = 0x16,
	READ_WRITE_MULTIPLE_REGISTERS = 0x17,
	ENCAPSULATED_INTERFACE = 0x2B,
}

// Exception codes (MAP 7, Table 4). NONE (0) means "no exception" in callbacks.
constdef ExceptionCode : char
{
	NONE = 0x00,
	ILLEGAL_FUNCTION = 0x01,
	ILLEGAL_DATA_ADDRESS = 0x02,
	ILLEGAL_DATA_VALUE = 0x03,
	SERVER_DEVICE_FAILURE = 0x04,
	ACKNOWLEDGE = 0x05,
	SERVER_DEVICE_BUSY = 0x06,
	MEMORY_PARITY_ERROR = 0x08,
	GATEWAY_PATH_UNAVAILABLE = 0x0A,
	GATEWAY_TARGET_NO_RESPONSE = 0x0B,
}

// Tables of the data model (MAP 4.3)
enum Table { COILS, DISCRETE_INPUTS, HOLDING_REGISTERS, INPUT_REGISTERS }

// A peer may send any byte as exception code (0x07, 0x09, vendor codes, even 0): keep it raw.
fn ExceptionCode raw_exception(char code) @inline => (ExceptionCode)code;

const char MEI_READ_DEVICE_ID = 0x0E;   // MAP 6.21: MEI type 0x0E

// Limits (MAP 4.1, 6.x, MTCP 3.1.1)
const usz MAX_PDU = 253;
const usz MAX_TCP_ADU = 260;            // 7 MBAP + 253 PDU
const usz MAX_RTU_ADU = 256;            // 1 addr + 253 PDU + 2 CRC
const usz MBAP_LEN = 7;
const ushort MAX_READ_BITS = 2000;      // FC 1, 2
const ushort MAX_READ_REGS = 125;       // FC 3, 4
const ushort MAX_WRITE_BITS = 1968;     // FC 15 (0x7B0)
const ushort MAX_WRITE_REGS = 123;      // FC 16 (0x7B)
const ushort MAX_RW_READ_REGS = 125;    // FC 23 read part
const ushort MAX_RW_WRITE_REGS = 121;   // FC 23 write part (0x79)

// Time: the sans-IO core never reads a clock. Callers pass a std::time::Clock (monotonic) and configure std::time::Duration timeouts.

fn bool is_exception_fc(char fc) @inline => (fc & 0x80) != 0;

// Library version. Kept equal to "version" in project.json by tools/bump_version.c3 and checked by a test.
const String VERSION = "0.1.0";

// The only place time enters the adapters: a monotonic clock. Tests replace it.
alias ClockFn = fn Clock();

fn Clock real_clock()
{
	return clock::now();
}

// A fault of another library's transport has its own identity: TIMEOUT is matched by name.
fn bool is_timeout(fault f)
{
	return f == TIMEOUT || f.short_name() == "TIMEOUT";
}
