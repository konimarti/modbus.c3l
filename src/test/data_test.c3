module modbus::data_test;

import modbus;
import modbus::data;

// -----------------------------------------------------------------------------
// 32-bit integer tests
// -----------------------------------------------------------------------------

fn void test_u32_abcd() @test
{
	ushort[2] regs;
	data::set_u32(&regs, 0, 0x12345678, Order.ABCD)!!;
	assert(regs[0] == 0x1234);
	assert(regs[1] == 0x5678);
	uint val = data::get_u32(&regs, 0, Order.ABCD)!!;
	assert(val == 0x12345678);
}

fn void test_u32_cdab() @test
{
	ushort[2] regs;
	data::set_u32(&regs, 0, 0x12345678, Order.CDAB)!!;
	assert(regs[0] == 0x5678);
	assert(regs[1] == 0x1234);
	uint val = data::get_u32(&regs, 0, Order.CDAB)!!;
	assert(val == 0x12345678);
}

fn void test_u32_badc() @test
{
	ushort[2] regs;
	data::set_u32(&regs, 0, 0x12345678, Order.BADC)!!;
	assert(regs[0] == 0x3412);
	assert(regs[1] == 0x7856);
	uint val = data::get_u32(&regs, 0, Order.BADC)!!;
	assert(val == 0x12345678);
}

fn void test_u32_dcba() @test
{
	ushort[2] regs;
	data::set_u32(&regs, 0, 0x12345678, Order.DCBA)!!;
	assert(regs[0] == 0x7856);
	assert(regs[1] == 0x3412);
	uint val = data::get_u32(&regs, 0, Order.DCBA)!!;
	assert(val == 0x12345678);
}

fn void test_i32_minus_one() @test
{
	ushort[2] regs;
	data::set_i32(&regs, 0, -1, Order.ABCD)!!;
	assert(regs[0] == 0xFFFF);
	assert(regs[1] == 0xFFFF);
	int val = data::get_i32(&regs, 0, Order.ABCD)!!;
	assert(val == -1);
}

fn void test_i32_minus_two_abcd() @test
{
	ushort[2] regs;
	data::set_i32(&regs, 0, -2, Order.ABCD)!!;
	assert(regs[0] == 0xFFFF);
	assert(regs[1] == 0xFFFE);
	int val = data::get_i32(&regs, 0, Order.ABCD)!!;
	assert(val == -2);
}

fn void test_i32_minus_two_cdab() @test
{
	ushort[2] regs;
	data::set_i32(&regs, 0, -2, Order.CDAB)!!;
	assert(regs[0] == 0xFFFE);
	assert(regs[1] == 0xFFFF);
	int val = data::get_i32(&regs, 0, Order.CDAB)!!;
	assert(val == -2);
}

fn void test_i32_minus_two_badc() @test
{
	ushort[2] regs;
	data::set_i32(&regs, 0, -2, Order.BADC)!!;
	assert(regs[0] == 0xFFFF);
	assert(regs[1] == 0xFEFF);
	int val = data::get_i32(&regs, 0, Order.BADC)!!;
	assert(val == -2);
}

fn void test_i32_minus_two_dcba() @test
{
	ushort[2] regs;
	data::set_i32(&regs, 0, -2, Order.DCBA)!!;
	assert(regs[0] == 0xFEFF);
	assert(regs[1] == 0xFFFF);
	int val = data::get_i32(&regs, 0, Order.DCBA)!!;
	assert(val == -2);
}

// -----------------------------------------------------------------------------
// 16-bit integer tests
// -----------------------------------------------------------------------------

fn void test_u16_abcd() @test
{
	ushort[1] regs;
	data::set_u16(&regs, 0, 0x1234, Order.ABCD)!!;
	assert(regs[0] == 0x1234);
	assert(data::get_u16(&regs, 0, Order.ABCD)!! == 0x1234);
}

fn void test_u16_cdab() @test
{
	ushort[1] regs;
	data::set_u16(&regs, 0, 0x1234, Order.CDAB)!!;
	assert(regs[0] == 0x1234);
	assert(data::get_u16(&regs, 0, Order.CDAB)!! == 0x1234);
}

fn void test_u16_badc() @test
{
	ushort[1] regs;
	data::set_u16(&regs, 0, 0x1234, Order.BADC)!!;
	assert(regs[0] == 0x3412);
	assert(data::get_u16(&regs, 0, Order.BADC)!! == 0x1234);
}

fn void test_u16_dcba() @test
{
	ushort[1] regs;
	data::set_u16(&regs, 0, 0x1234, Order.DCBA)!!;
	assert(regs[0] == 0x3412);
	assert(data::get_u16(&regs, 0, Order.DCBA)!! == 0x1234);
}

fn void test_u16_max() @test
{
	ushort[1] regs;
	data::set_u16(&regs, 0, 65535, Order.ABCD)!!;
	assert(regs[0] == 0xFFFF);
	assert(data::get_u16(&regs, 0, Order.ABCD)!! == 65535);
}

fn void test_i16_minus_one() @test
{
	ushort[1] regs;
	data::set_i16(&regs, 0, -1, Order.ABCD)!!;
	assert(regs[0] == 0xFFFF);
	assert(data::get_i16(&regs, 0, Order.ABCD)!! == -1);
}

fn void test_i16_minus_two() @test
{
	ushort[1] regs;
	data::set_i16(&regs, 0, -2, Order.ABCD)!!;
	assert(regs[0] == 0xFFFE);
	assert(data::get_i16(&regs, 0, Order.ABCD)!! == -2);
}

fn void test_i16_orders() @test
{
	ushort[1] regs;
	data::set_i16(&regs, 0, -2, Order.BADC)!!;
	assert(regs[0] == 0xFEFF);
	assert(data::get_i16(&regs, 0, Order.BADC)!! == -2);
	data::set_i16(&regs, 0, -2, Order.DCBA)!!;
	assert(regs[0] == 0xFEFF);
	assert(data::get_i16(&regs, 0, Order.DCBA)!! == -2);
}

// -----------------------------------------------------------------------------
// 64-bit integer tests
// -----------------------------------------------------------------------------

fn void test_u64_abcd() @test
{
	ushort[4] regs;
	data::set_u64(&regs, 0, 0x0102030405060708, Order.ABCD)!!;
	assert(regs[0] == 0x0102);
	assert(regs[1] == 0x0304);
	assert(regs[2] == 0x0506);
	assert(regs[3] == 0x0708);
	ulong val = data::get_u64(&regs, 0, Order.ABCD)!!;
	assert(val == 0x0102030405060708);
}

fn void test_u64_cdab() @test
{
	ushort[4] regs;
	data::set_u64(&regs, 0, 0x0102030405060708, Order.CDAB)!!;
	assert(regs[0] == 0x0708);
	assert(regs[1] == 0x0506);
	assert(regs[2] == 0x0304);
	assert(regs[3] == 0x0102);
	ulong val = data::get_u64(&regs, 0, Order.CDAB)!!;
	assert(val == 0x0102030405060708);
}

fn void test_u64_badc() @test
{
	ushort[4] regs;
	data::set_u64(&regs, 0, 0x0102030405060708, Order.BADC)!!;
	assert(regs[0] == 0x0201);
	assert(regs[1] == 0x0403);
	assert(regs[2] == 0x0605);
	assert(regs[3] == 0x0807);
	ulong val = data::get_u64(&regs, 0, Order.BADC)!!;
	assert(val == 0x0102030405060708);
}

fn void test_u64_dcba() @test
{
	ushort[4] regs;
	data::set_u64(&regs, 0, 0x0102030405060708, Order.DCBA)!!;
	assert(regs[0] == 0x0807);
	assert(regs[1] == 0x0605);
	assert(regs[2] == 0x0403);
	assert(regs[3] == 0x0201);
	ulong val = data::get_u64(&regs, 0, Order.DCBA)!!;
	assert(val == 0x0102030405060708);
}

fn void test_u64_max() @test
{
	ushort[4] regs;
	data::set_u64(&regs, 0, 0xFFFFFFFFFFFFFFFF, Order.ABCD)!!;
	for (usz i = 0; i < 4; i++) assert(regs[i] == 0xFFFF);
	assert(data::get_u64(&regs, 0, Order.ABCD)!! == 0xFFFFFFFFFFFFFFFF);
}

fn void test_i64_minus_one() @test
{
	ushort[4] regs;
	data::set_i64(&regs, 0, -1L, Order.ABCD)!!;
	for (usz i = 0; i < 4; i++) assert(regs[i] == 0xFFFF);
	assert(data::get_i64(&regs, 0, Order.ABCD)!! == -1L);
}

fn void test_i64_minus_two_abcd() @test
{
	ushort[4] regs;
	data::set_i64(&regs, 0, -2L, Order.ABCD)!!;
	assert(regs[0] == 0xFFFF);
	assert(regs[1] == 0xFFFF);
	assert(regs[2] == 0xFFFF);
	assert(regs[3] == 0xFFFE);
	assert(data::get_i64(&regs, 0, Order.ABCD)!! == -2L);
}

fn void test_i64_minus_two_cdab() @test
{
	ushort[4] regs;
	data::set_i64(&regs, 0, -2L, Order.CDAB)!!;
	assert(regs[0] == 0xFFFE);
	assert(regs[1] == 0xFFFF);
	assert(regs[2] == 0xFFFF);
	assert(regs[3] == 0xFFFF);
	assert(data::get_i64(&regs, 0, Order.CDAB)!! == -2L);
}

// -----------------------------------------------------------------------------
// float32 tests
// -----------------------------------------------------------------------------

fn void test_f32_one_abcd() @test
{
	ushort[2] regs;
	data::set_f32(&regs, 0, 1.0f, Order.ABCD)!!;
	assert(regs[0] == 0x3F80);
	assert(regs[1] == 0x0000);
	float val = data::get_f32(&regs, 0, Order.ABCD)!!;
	assert(val == 1.0f);
}

fn void test_f32_one_cdab() @test
{
	ushort[2] regs;
	data::set_f32(&regs, 0, 1.0f, Order.CDAB)!!;
	assert(regs[0] == 0x0000);
	assert(regs[1] == 0x3F80);
	float val = data::get_f32(&regs, 0, Order.CDAB)!!;
	assert(val == 1.0f);
}

fn void test_f32_one_badc() @test
{
	ushort[2] regs;
	data::set_f32(&regs, 0, 1.0f, Order.BADC)!!;
	assert(regs[0] == 0x803F);
	assert(regs[1] == 0x0000);
	float val = data::get_f32(&regs, 0, Order.BADC)!!;
	assert(val == 1.0f);
}

fn void test_f32_one_dcba() @test
{
	ushort[2] regs;
	data::set_f32(&regs, 0, 1.0f, Order.DCBA)!!;
	assert(regs[0] == 0x0000);
	assert(regs[1] == 0x803F);
	float val = data::get_f32(&regs, 0, Order.DCBA)!!;
	assert(val == 1.0f);
}

fn void test_f32_hundred_abcd() @test
{
	ushort[2] regs;
	data::set_f32(&regs, 0, 100.0f, Order.ABCD)!!;
	assert(regs[0] == 0x42C8);
	assert(regs[1] == 0x0000);
	float val = data::get_f32(&regs, 0, Order.ABCD)!!;
	assert(val == 100.0f);
}

fn void test_f32_hundred_cdab() @test
{
	ushort[2] regs;
	data::set_f32(&regs, 0, 100.0f, Order.CDAB)!!;
	assert(regs[0] == 0x0000);
	assert(regs[1] == 0x42C8);
	float val = data::get_f32(&regs, 0, Order.CDAB)!!;
	assert(val == 100.0f);
}

fn void test_f32_hundred_badc() @test
{
	ushort[2] regs;
	data::set_f32(&regs, 0, 100.0f, Order.BADC)!!;
	assert(regs[0] == 0xC842);
	assert(regs[1] == 0x0000);
	float val = data::get_f32(&regs, 0, Order.BADC)!!;
	assert(val == 100.0f);
}

fn void test_f32_hundred_dcba() @test
{
	ushort[2] regs;
	data::set_f32(&regs, 0, 100.0f, Order.DCBA)!!;
	assert(regs[0] == 0x0000);
	assert(regs[1] == 0xC842);
	float val = data::get_f32(&regs, 0, Order.DCBA)!!;
	assert(val == 100.0f);
}

fn void test_f32_minus_two_point_five_abcd() @test
{
	ushort[2] regs;
	data::set_f32(&regs, 0, -2.5f, Order.ABCD)!!;
	assert(regs[0] == 0xC020);
	assert(regs[1] == 0x0000);
	float val = data::get_f32(&regs, 0, Order.ABCD)!!;
	assert(val == -2.5f);
}

fn void test_f32_minus_two_point_five_cdab() @test
{
	ushort[2] regs;
	data::set_f32(&regs, 0, -2.5f, Order.CDAB)!!;
	assert(regs[0] == 0x0000);
	assert(regs[1] == 0xC020);
	float val = data::get_f32(&regs, 0, Order.CDAB)!!;
	assert(val == -2.5f);
}

fn void test_f32_minus_two_point_five_badc() @test
{
	ushort[2] regs;
	data::set_f32(&regs, 0, -2.5f, Order.BADC)!!;
	assert(regs[0] == 0x20C0);
	assert(regs[1] == 0x0000);
	float val = data::get_f32(&regs, 0, Order.BADC)!!;
	assert(val == -2.5f);
}

fn void test_f32_minus_two_point_five_dcba() @test
{
	ushort[2] regs;
	data::set_f32(&regs, 0, -2.5f, Order.DCBA)!!;
	assert(regs[0] == 0x0000);
	assert(regs[1] == 0x20C0);
	float val = data::get_f32(&regs, 0, Order.DCBA)!!;
	assert(val == -2.5f);
}

fn void test_f32_pi_abcd() @test
{
	ushort[2] regs;
	data::set_u32(&regs, 0, 0x42F6E979, Order.ABCD)!!;
	assert(regs[0] == 0x42F6);
	assert(regs[1] == 0xE979);
	uint bits = bitcast(data::get_f32(&regs, 0, Order.ABCD)!!, uint);
	assert(bits == 0x42F6E979);
}

fn void test_f32_pi_cdab() @test
{
	ushort[2] regs;
	data::set_u32(&regs, 0, 0x42F6E979, Order.CDAB)!!;
	assert(regs[0] == 0xE979);
	assert(regs[1] == 0x42F6);
	uint bits = bitcast(data::get_f32(&regs, 0, Order.CDAB)!!, uint);
	assert(bits == 0x42F6E979);
}

fn void test_f32_pi_badc() @test
{
	ushort[2] regs;
	data::set_u32(&regs, 0, 0x42F6E979, Order.BADC)!!;
	assert(regs[0] == 0xF642);
	assert(regs[1] == 0x79E9);
	uint bits = bitcast(data::get_f32(&regs, 0, Order.BADC)!!, uint);
	assert(bits == 0x42F6E979);
}

fn void test_f32_pi_dcba() @test
{
	ushort[2] regs;
	data::set_u32(&regs, 0, 0x42F6E979, Order.DCBA)!!;
	assert(regs[0] == 0x79E9);
	assert(regs[1] == 0xF642);
	uint bits = bitcast(data::get_f32(&regs, 0, Order.DCBA)!!, uint);
	assert(bits == 0x42F6E979);
}

fn void test_f32_nan_bit_exact() @test
{
	Order[4] orders = { Order.ABCD, Order.CDAB, Order.BADC, Order.DCBA };
	foreach (o : orders)
	{
		ushort[2] regs;
		float nan_val = bitcast(0x7FC00000, float);
		data::set_f32(&regs, 0, nan_val, o)!!;
		float read_back = data::get_f32(&regs, 0, o)!!;
		uint bits = bitcast(read_back, uint);
		assert(bits == 0x7FC00000);
	}
}

fn void test_f32_neg_zero_bit_exact() @test
{
	Order[4] orders = { Order.ABCD, Order.CDAB, Order.BADC, Order.DCBA };
	foreach (o : orders)
	{
		ushort[2] regs;
		float neg_zero = bitcast(0x80000000, float);
		data::set_f32(&regs, 0, neg_zero, o)!!;
		float read_back = data::get_f32(&regs, 0, o)!!;
		uint bits = bitcast(read_back, uint);
		assert(bits == 0x80000000);
	}
}

// -----------------------------------------------------------------------------
// float64 tests
// -----------------------------------------------------------------------------

fn void test_f64_one_abcd() @test
{
	ushort[4] regs;
	data::set_f64(&regs, 0, 1.0, Order.ABCD)!!;
	assert(regs[0] == 0x3FF0);
	assert(regs[1] == 0x0000);
	assert(regs[2] == 0x0000);
	assert(regs[3] == 0x0000);
	double val = data::get_f64(&regs, 0, Order.ABCD)!!;
	assert(val == 1.0);
}

fn void test_f64_one_cdab() @test
{
	ushort[4] regs;
	data::set_f64(&regs, 0, 1.0, Order.CDAB)!!;
	assert(regs[0] == 0x0000);
	assert(regs[1] == 0x0000);
	assert(regs[2] == 0x0000);
	assert(regs[3] == 0x3FF0);
	double val = data::get_f64(&regs, 0, Order.CDAB)!!;
	assert(val == 1.0);
}

fn void test_f64_one_badc() @test
{
	ushort[4] regs;
	data::set_f64(&regs, 0, 1.0, Order.BADC)!!;
	assert(regs[0] == 0xF03F);
	assert(regs[1] == 0x0000);
	assert(regs[2] == 0x0000);
	assert(regs[3] == 0x0000);
	double val = data::get_f64(&regs, 0, Order.BADC)!!;
	assert(val == 1.0);
}

fn void test_f64_one_dcba() @test
{
	ushort[4] regs;
	data::set_f64(&regs, 0, 1.0, Order.DCBA)!!;
	assert(regs[0] == 0x0000);
	assert(regs[1] == 0x0000);
	assert(regs[2] == 0x0000);
	assert(regs[3] == 0xF03F);
	double val = data::get_f64(&regs, 0, Order.DCBA)!!;
	assert(val == 1.0);
}

fn void test_f64_minus_two_point_five() @test
{
	ushort[4] regs;
	data::set_f64(&regs, 0, -2.5, Order.ABCD)!!;
	assert(regs[0] == 0xC004);
	assert(regs[1] == 0x0000);
	assert(regs[2] == 0x0000);
	assert(regs[3] == 0x0000);
	double val = data::get_f64(&regs, 0, Order.ABCD)!!;
	assert(val == -2.5);
}

fn void test_f64_nan_bit_exact() @test
{
	Order[4] orders = { Order.ABCD, Order.CDAB, Order.BADC, Order.DCBA };
	foreach (o : orders)
	{
		ushort[4] regs;
		double nan_val = bitcast(0x7FF8000000000000L, double);
		data::set_f64(&regs, 0, nan_val, o)!!;
		double read_back = data::get_f64(&regs, 0, o)!!;
		ulong bits = bitcast(read_back, ulong);
		assert(bits == 0x7FF8000000000000L);
	}
}

fn void test_f64_neg_zero_bit_exact() @test
{
	Order[4] orders = { Order.ABCD, Order.CDAB, Order.BADC, Order.DCBA };
	foreach (o : orders)
	{
		ushort[4] regs;
		double neg_zero = bitcast(0x8000000000000000L, double);
		data::set_f64(&regs, 0, neg_zero, o)!!;
		double read_back = data::get_f64(&regs, 0, o)!!;
		ulong bits = bitcast(read_back, ulong);
		assert(bits == 0x8000000000000000L);
	}
}

// -----------------------------------------------------------------------------
// String tests
// -----------------------------------------------------------------------------

fn void test_string_ab() @test
{
	ushort[1] regs;
	data::set_string(&regs, 0, 1, "AB")!!;
	assert(regs[0] == 0x4142);
	char[10] buf;
	usz len = data::get_string(&regs, 0, 1, &buf)!!;
	assert(len == 2);
	assert(buf[0] == 'A');
	assert(buf[1] == 'B');
}

fn void test_string_abc_nul_trimmed() @test
{
	ushort[2] regs = { 0x4142, 0x4300 };
	char[10] buf;
	usz len = data::get_string(&regs, 0, 2, &buf)!!;
	assert(len == 3);
	assert(buf[0] == 'A');
	assert(buf[1] == 'B');
	assert(buf[2] == 'C');
}

fn void test_string_abc_space_trimmed() @test
{
	ushort[2] regs = { 0x4142, 0x4320 };
	char[10] buf;
	usz len = data::get_string(&regs, 0, 2, &buf)!!;
	assert(len == 3);
	assert(buf[0] == 'A');
	assert(buf[1] == 'B');
	assert(buf[2] == 'C');
}

fn void test_string_abcd_swapped() @test
{
	ushort[2] regs = { 0x4241, 0x4443 };
	char[10] buf;
	usz len = data::get_string(&regs, 0, 2, &buf, low_first: true)!!;
	assert(len == 4);
	assert(buf[0] == 'A');
	assert(buf[1] == 'B');
	assert(buf[2] == 'C');
	assert(buf[3] == 'D');
}

fn void test_string_low_first() @test
{
	ushort[1] regs = { 0x4142 };
	char[10] buf;
	usz len = data::get_string(&regs, 0, 1, &buf, low_first: true)!!;
	assert(len == 2);
	assert(buf[0] == 'B');
	assert(buf[1] == 'A');
}

fn void test_string_set_nul_pad() @test
{
	ushort[2] regs;
	data::set_string(&regs, 0, 2, "ABC")!!;
	assert(regs[0] == 0x4142);
	assert(regs[1] == 0x4300);
}

fn void test_string_set_space_pad() @test
{
	ushort[2] regs;
	data::set_string(&regs, 0, 2, "ABC", pad: ' ')!!;
	assert(regs[0] == 0x4142);
	assert(regs[1] == 0x4320);
}

fn void test_string_set_odd_length() @test
{
	ushort[1] regs;
	data::set_string(&regs, 0, 1, "A", pad: ' ')!!;
	assert(regs[0] == 0x4120);
}

fn void test_string_raw_bytes() @test
{
	ushort[1] regs = { 0xC4E9 };
	char[10] buf;
	usz len = data::get_string(&regs, 0, 1, &buf)!!;
	assert(len == 2);
	assert(buf[0] == (char)0xC4);
	assert(buf[1] == (char)0xE9);
}

fn void test_string_ascii_only_valid() @test
{
	ushort[2] regs = { 0x4142, 0x4344 };
	char[10] buf;
	usz len = data::get_string(&regs, 0, 2, &buf, ascii_only: true)!!;
	assert(len == 4);
}

fn void test_string_ascii_only_reject() @test
{
	ushort[1] regs = { 0xC4E9 };
	char[10] buf;
	assert(@catch(data::get_string(&regs, 0, 1, &buf, ascii_only: true)) == modbus::BAD_STRING);
}

fn void test_string_set_too_long() @test
{
	ushort[1] regs;
	assert(@catch(data::set_string(&regs, 0, 1, "ABCD")) == modbus::BAD_STRING);
}

fn void test_string_get_buffer_too_small() @test
{
	ushort[2] regs = { 0x4142, 0x4344 };
	char[2] buf;
	assert(@catch(data::get_string(&regs, 0, 2, &buf)) == modbus::BAD_STRING);
}

fn void test_string_empty() @test
{
	ushort[1] regs;
	data::set_string(&regs, 0, 1, "")!!;
	assert(regs[0] == 0x0000);
	char[10] buf;
	usz len = data::get_string(&regs, 0, 1, &buf)!!;
	assert(len == 0);
}

fn void test_string_all_pad() @test
{
	ushort[2] regs = { 0x2020, 0x2020 };
	char[10] buf;
	usz len = data::get_string(&regs, 0, 2, &buf)!!;
	assert(len == 0);
}

// -----------------------------------------------------------------------------
// Short registers & bounds tests
// -----------------------------------------------------------------------------

fn void test_fault_get_u16_out_of_bounds() @test
{
	ushort[1] regs;
	assert(@catch(data::get_u16(&regs, 1)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_get_i16_out_of_bounds() @test
{
	ushort[1] regs;
	assert(@catch(data::get_i16(&regs, 1)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_set_u16_out_of_bounds() @test
{
	ushort[1] regs;
	assert(@catch(data::set_u16(&regs, 1, 0x1234)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_set_i16_out_of_bounds() @test
{
	ushort[1] regs;
	assert(@catch(data::set_i16(&regs, 1, -1)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_get_u32_one_reg() @test
{
	ushort[1] regs;
	assert(@catch(data::get_u32(&regs, 0)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_get_i32_one_reg() @test
{
	ushort[1] regs;
	assert(@catch(data::get_i32(&regs, 0)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_set_u32_one_reg() @test
{
	ushort[1] regs;
	assert(@catch(data::set_u32(&regs, 0, 0x12345678)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_set_i32_one_reg() @test
{
	ushort[1] regs;
	assert(@catch(data::set_i32(&regs, 0, -1)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_get_f32_one_reg() @test
{
	ushort[1] regs;
	assert(@catch(data::get_f32(&regs, 0)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_set_f32_one_reg() @test
{
	ushort[1] regs;
	assert(@catch(data::set_f32(&regs, 0, 1.0f)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_get_u64_three_regs() @test
{
	ushort[3] regs;
	assert(@catch(data::get_u64(&regs, 0)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_get_i64_three_regs() @test
{
	ushort[3] regs;
	assert(@catch(data::get_i64(&regs, 0)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_set_u64_three_regs() @test
{
	ushort[3] regs;
	assert(@catch(data::set_u64(&regs, 0, 0x0102030405060708)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_set_i64_three_regs() @test
{
	ushort[3] regs;
	assert(@catch(data::set_i64(&regs, 0, -1L)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_get_f64_three_regs() @test
{
	ushort[3] regs;
	assert(@catch(data::get_f64(&regs, 0)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_set_f64_three_regs() @test
{
	ushort[3] regs;
	assert(@catch(data::set_f64(&regs, 0, 1.0)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_get_string_out_of_bounds() @test
{
	ushort[2] regs;
	char[10] buf;
	assert(@catch(data::get_string(&regs, 1, 2, &buf)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_set_string_out_of_bounds() @test
{
	ushort[2] regs;
	assert(@catch(data::set_string(&regs, 1, 2, "ABC")) == modbus::SHORT_REGISTERS);
}

fn void test_fault_offset_past_end() @test
{
	ushort[2] regs;
	assert(@catch(data::get_u16(&regs, 2)) == modbus::SHORT_REGISTERS);
}

fn void test_fault_get_u32_offset_span() @test
{
	ushort[3] regs;
	assert(@catch(data::get_u32(&regs, 2)) == modbus::SHORT_REGISTERS);
}

// -----------------------------------------------------------------------------
// Coil packing tests
// -----------------------------------------------------------------------------

fn void test_coil_pack_ten() @test
{
	bool[10] coils = { true, false, true, true, false, false, true, true, true, false };
	char[4] out;
	usz len = data::pack_coils(&coils, &out)!!;
	assert(len == 2);
	assert(out[0] == (char)0xCD);
	assert(out[1] == (char)0x01);
}

fn void test_coil_pack_nineteen() @test
{
	// V2: CD 6B 05
	// CD = 11001101 (bits 0..7)
	// 6B = 01101011 (bits 8..15)
	// 05 = 00000101 (bits 16..18)
	bool[19] coils = {
		true, false, true, true, false, false, true, true,
		true, true, false, true, false, true, true, false,
		true, false, true
	};
	char[4] out;
	usz len = data::pack_coils(&coils, &out)!!;
	assert(len == 3);
	assert(out[0] == (char)0xCD);
	assert(out[1] == (char)0x6B);
	assert(out[2] == (char)0x05);
}

fn void test_coil_pack_one_on() @test
{
	bool[1] coils = { true };
	char[2] out;
	usz len = data::pack_coils(&coils, &out)!!;
	assert(len == 1);
	assert(out[0] == (char)0x01);
}

fn void test_coil_pack_nine_on() @test
{
	bool[9] coils = { true, true, true, true, true, true, true, true, true };
	char[2] out;
	usz len = data::pack_coils(&coils, &out)!!;
	assert(len == 2);
	assert(out[0] == (char)0xFF);
	assert(out[1] == (char)0x01);
}

fn void test_coil_pack_zero() @test
{
	bool[] coils = {};
	char[2] out;
	usz len = data::pack_coils(coils, &out)!!;
	assert(len == 0);
}

fn void test_coil_pack_eight() @test
{
	bool[8] coils = { true, true, true, true, true, true, true, true };
	char[2] out;
	usz len = data::pack_coils(&coils, &out)!!;
	assert(len == 1);
	assert(out[0] == (char)0xFF);
}

fn void test_coil_unpack_ten() @test
{
	char[2] bytes = { (char)0xCD, (char)0x01 };
	bool[10] out;
	data::unpack_coils(&bytes, 10, &out)!!;
	bool[10] expected = { true, false, true, true, false, false, true, true, true, false };
	for (usz i = 0; i < 10; i++)
	{
		assert(out[i] == expected[i]);
	}
}

fn void test_coil_unpack_nineteen() @test
{
	char[3] bytes = { (char)0xCD, (char)0x6B, (char)0x05 };
	bool[19] out;
	data::unpack_coils(&bytes, 19, &out)!!;
	bool[19] expected = {
		true, false, true, true, false, false, true, true,
		true, true, false, true, false, true, true, false,
		true, false, true
	};
	for (usz i = 0; i < 19; i++)
	{
		assert(out[i] == expected[i]);
	}
}

fn void test_coil_unpack_one() @test
{
	char[1] bytes = { (char)0x01 };
	bool[1] out;
	data::unpack_coils(&bytes, 1, &out)!!;
	assert(out[0] == true);
}

fn void test_coil_unpack_nine() @test
{
	char[2] bytes = { (char)0xFF, (char)0x01 };
	bool[9] out;
	data::unpack_coils(&bytes, 9, &out)!!;
	for (usz i = 0; i < 9; i++)
	{
		assert(out[i] == true);
	}
}

fn void test_coil_roundtrip() @test
{
	bool[35] coils;
	for (usz i = 0; i < 35; i++)
	{
		coils[i] = (i % 3 == 0) || (i % 7 == 0);
	}
	char[5] buf;
	usz len = data::pack_coils(&coils, &buf)!!;
	assert(len == 5);
	bool[35] unpacked;
	data::unpack_coils(&buf, 35, &unpacked)!!;
	for (usz i = 0; i < 35; i++)
	{
		assert(unpacked[i] == coils[i]);
	}
}

fn void test_coil_pack_buffer_too_small() @test
{
	bool[10] coils;
	char[1] out;
	assert(@catch(data::pack_coils(&coils, &out)) == modbus::BUFFER_TOO_SMALL);
}

fn void test_coil_unpack_buffer_too_small() @test
{
	char[2] bytes = { (char)0xCD, (char)0x01 };
	bool[5] out;
	assert(@catch(data::unpack_coils(&bytes, 10, &out)) == modbus::BUFFER_TOO_SMALL);
}
