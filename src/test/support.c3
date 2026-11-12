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

// An allocator that serves a fixed number of allocations and then fails; counts what is still live,
// so a test can check that a failed init gave back everything it had taken.
struct LimitedAllocator (Allocator)
{
	int allowed;
	int live;
}

fn void*? LimitedAllocator.acquire(&self, sz bytes, AllocInitType init_type, sz alignment) @dynamic
{
	if (self.allowed <= 0) return mem::OUT_OF_MEMORY~;
	self.allowed--;
	self.live++;
	return mem::calloc(bytes);
}

fn void*? LimitedAllocator.resize(&self, void* old_ptr, sz new_bytes, sz alignment) @dynamic
{
	return mem::OUT_OF_MEMORY~;
}

fn void LimitedAllocator.release(&self, void* old_ptr, bool aligned) @dynamic
{
	self.live--;
	mem::free(old_ptr);
}
