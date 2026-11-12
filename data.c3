module modbus::data;

import modbus;

// 16-bit registers <-> values. Registers hold big-endian bytes on the wire (MAP 4.2);
// the word/byte order of multi-register values is device-specific.
// Letters name the byte positions of the value, ABCD = most significant first.
enum Order
{
	ABCD,    // big endian: high word first, bytes in order (Modbus default for one register)
	CDAB,    // word-swapped (low word first)
	BADC,    // byte-swapped inside each word
	DCBA,    // little endian: both swapped
}

fn void? read_bytes(ushort[] regs, usz at, usz nregs, Order o, char[] out_bytes)
{
	if (regs.len < nregs || at > regs.len - nregs) return modbus::SHORT_REGISTERS~;
	bool swap_words = (o == Order.CDAB || o == Order.DCBA);
	bool swap_bytes = (o == Order.BADC || o == Order.DCBA);
	for (usz i = 0; i < nregs; i++)
	{
		usz w = swap_words ? (nregs - 1 - i) : i;
		ushort reg = regs[at + i];
		if (!swap_bytes)
		{
			out_bytes[2 * w] = (char)(reg >> 8);
			out_bytes[2 * w + 1] = (char)(reg & 0xFF);
		}
		else
		{
			out_bytes[2 * w] = (char)(reg & 0xFF);
			out_bytes[2 * w + 1] = (char)(reg >> 8);
		}
	}
}

fn void? write_bytes(ushort[] regs, usz at, usz nregs, Order o, char[] in_bytes)
{
	if (regs.len < nregs || at > regs.len - nregs) return modbus::SHORT_REGISTERS~;
	bool swap_words = (o == Order.CDAB || o == Order.DCBA);
	bool swap_bytes = (o == Order.BADC || o == Order.DCBA);
	for (usz i = 0; i < nregs; i++)
	{
		usz w = swap_words ? (nregs - 1 - i) : i;
		if (!swap_bytes)
		{
			regs[at + i] = ((ushort)in_bytes[2 * w] << 8) | (ushort)in_bytes[2 * w + 1];
		}
		else
		{
			regs[at + i] = ((ushort)in_bytes[2 * w + 1] << 8) | (ushort)in_bytes[2 * w];
		}
	}
}

fn short? get_i16(ushort[] regs, usz at, Order o = ABCD)
{
	ushort u = get_u16(regs, at, o)!;
	return (short)u;
}

fn ushort? get_u16(ushort[] regs, usz at, Order o = ABCD)
{
	char[2] b;
	read_bytes(regs, at, 1, o, &b)!;
	return ((ushort)b[0] << 8) | (ushort)b[1];
}

fn int? get_i32(ushort[] regs, usz at, Order o = ABCD)
{
	uint u = get_u32(regs, at, o)!;
	return (int)u;
}

fn uint? get_u32(ushort[] regs, usz at, Order o = ABCD)
{
	char[4] b;
	read_bytes(regs, at, 2, o, &b)!;
	return ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | (uint)b[3];
}

fn long? get_i64(ushort[] regs, usz at, Order o = ABCD)
{
	ulong u = get_u64(regs, at, o)!;
	return (long)u;
}

fn ulong? get_u64(ushort[] regs, usz at, Order o = ABCD)
{
	char[8] b;
	read_bytes(regs, at, 4, o, &b)!;
	ulong res = 0;
	for (usz i = 0; i < 8; i++)
	{
		res = (res << 8) | (ulong)b[i];
	}
	return res;
}

fn float? get_f32(ushort[] regs, usz at, Order o = ABCD)
{
	uint u = get_u32(regs, at, o)!;
	return bitcast(u, float);
}

fn double? get_f64(ushort[] regs, usz at, Order o = ABCD)
{
	ulong u = get_u64(regs, at, o)!;
	return bitcast(u, double);
}

fn void? set_i16(ushort[] regs, usz at, short v, Order o = ABCD)
{
	return set_u16(regs, at, (ushort)v, o);
}

fn void? set_u16(ushort[] regs, usz at, ushort v, Order o = ABCD)
{
	char[2] b = { (char)(v >> 8), (char)(v & 0xFF) };
	return write_bytes(regs, at, 1, o, &b);
}

fn void? set_u32(ushort[] regs, usz at, uint v, Order o = ABCD)
{
	char[4] b = {
		(char)(v >> 24),
		(char)((v >> 16) & 0xFF),
		(char)((v >> 8) & 0xFF),
		(char)(v & 0xFF)
	};
	return write_bytes(regs, at, 2, o, &b);
}

fn void? set_i32(ushort[] regs, usz at, int v, Order o = ABCD)
{
	return set_u32(regs, at, (uint)v, o);
}

fn void? set_u64(ushort[] regs, usz at, ulong v, Order o = ABCD)
{
	char[8] b;
	for (usz i = 0; i < 8; i++)
	{
		b[7 - i] = (char)((v >> (i * 8)) & 0xFF);
	}
	return write_bytes(regs, at, 4, o, &b);
}

fn void? set_i64(ushort[] regs, usz at, long v, Order o = ABCD)
{
	return set_u64(regs, at, (ulong)v, o);
}

fn void? set_f32(ushort[] regs, usz at, float v, Order o = ABCD)
{
	return set_u32(regs, at, bitcast(v, uint), o);
}

fn void? set_f64(ushort[] regs, usz at, double v, Order o = ABCD)
{
	return set_u64(regs, at, bitcast(v, ulong), o);
}

// Strings: two ASCII chars per register. `low_first` puts the first char in the low byte.
// Trailing NULs and spaces are trimmed on read; get_string copies the raw bytes into `out` (no UTF-8/ASCII
// assumption) and returns the length; `ascii_only` makes bytes > 0x7F fail with BAD_STRING.
// set_string pads the unused tail with `pad` (0 or ' '); too long -> BAD_STRING.
fn usz? get_string(ushort[] regs, usz at, usz nregs, char[] out, bool low_first = false, bool ascii_only = false)
{
	if (regs.len < nregs || at > regs.len - nregs) return modbus::SHORT_REGISTERS~;

	usz total = 2 * nregs;
	if (ascii_only)
	{
		for (usz i = 0; i < nregs; i++)
		{
			ushort r = regs[at + i];
			if ((r & 0x8080) != 0) return modbus::BAD_STRING~;
		}
	}

	usz trimmed_len = total;
	while (trimmed_len > 0)
	{
		usz byte_idx = trimmed_len - 1;
		usz reg_idx = byte_idx / 2;
		ushort r = regs[at + reg_idx];
		char b;
		if (!low_first)
		{
			b = (byte_idx % 2 == 0) ? (char)(r >> 8) : (char)(r & 0xFF);
		}
		else
		{
			b = (byte_idx % 2 == 0) ? (char)(r & 0xFF) : (char)(r >> 8);
		}
		if (b != 0 && b != ' ') break;
		trimmed_len--;
	}

	if (out.len < trimmed_len) return modbus::BAD_STRING~;

	for (usz i = 0; i < trimmed_len; i++)
	{
		usz reg_idx = i / 2;
		ushort r = regs[at + reg_idx];
		if (!low_first)
		{
			out[i] = (i % 2 == 0) ? (char)(r >> 8) : (char)(r & 0xFF);
		}
		else
		{
			out[i] = (i % 2 == 0) ? (char)(r & 0xFF) : (char)(r >> 8);
		}
	}

	return trimmed_len;
}

fn void? set_string(ushort[] regs, usz at, usz nregs, String s, bool low_first = false, char pad = 0)
{
	if (regs.len < nregs || at > regs.len - nregs) return modbus::SHORT_REGISTERS~;
	usz max_len = 2 * nregs;
	if (s.len > max_len) return modbus::BAD_STRING~;

	for (usz i = 0; i < nregs; i++)
	{
		usz idx0 = 2 * i;
		usz idx1 = 2 * i + 1;
		char b0 = (idx0 < s.len) ? s[idx0] : pad;
		char b1 = (idx1 < s.len) ? s[idx1] : pad;
		if (!low_first)
		{
			regs[at + i] = ((ushort)b0 << 8) | (ushort)b1;
		}
		else
		{
			regs[at + i] = ((ushort)b1 << 8) | (ushort)b0;
		}
	}
}

// Coil bit packing: first coil in the LSB of the first byte (MAP 6.1, 6.11).
// Unused trailing bits in the last byte are zeroed.
fn usz? pack_coils(bool[] coils, char[] out)
{
	usz nbytes = (coils.len + 7) / 8;
	if (out.len < nbytes) return modbus::BUFFER_TOO_SMALL~;
	for (usz i = 0; i < nbytes; i++)
	{
		out[i] = 0;
	}
	foreach (i, b : coils)
	{
		if (b) out[i / 8] |= (char)(1 << (i % 8));
	}
	return nbytes;
}

fn void? unpack_coils(char[] bytes, usz count, bool[] out)
{
	usz nbytes = (count + 7) / 8;
	if (bytes.len < nbytes || out.len < count) return modbus::BUFFER_TOO_SMALL~;
	for (usz i = 0; i < count; i++)
	{
		out[i] = ((bytes[i / 8] >> (i % 8)) & 1) != 0;
	}
}
