module modbus::support;

import std::core::mem;
import std::encoding::hex;

// Hex text ("01 03 00") to bytes, in the temp allocator.
fn char[] hx(String s)
{
	DString d = dstring::temp();
	foreach (c : s)
	{
		if (c != ' ') d.append_char(c);
	}
	return hex::tdecode(d.str_view())!!;
}

fn void assert_bytes(char[] got, String want_hex, String name = "")
{
	char[] want = hx(want_hex);
	assert(got.len == want.len, "%s: length got %d, want %d", name, got.len, want.len);
	foreach (i, b : want)
	{
		assert(got[i] == b, "%s: byte %d got %02x, want %02x", name, i, got[i], b);
	}
}

// Hex head followed by n zero bytes, in the temp allocator.
fn char[] padded(String head, usz n)
{
	char[] h = hx(head);
	char[] all = mem::temp_array(char, (sz)(h.len + n));
	mem::copy(all.ptr, h.ptr, (sz)h.len);
	return all;
}
