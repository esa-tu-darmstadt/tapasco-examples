#include "tanh.h"

/**
 * Implements tanh approximation:
 *
 * min(max(((n0 * x^2 + n1)/(x^2 + d0)) * x + x), -1), 1)
 */
template<size_t H, size_t W>
void mytanh(adf::input_buffer<float, adf::extents<H*W>> &in,
		adf::output_buffer<float, adf::extents<H*W>> &out)
{
	auto inIt = aie::cbegin_vector<VECTOR_SIZE>(in);
	auto outIt = aie::begin_vector<VECTOR_SIZE>(out);

	const float n0 = -8.73291016e-1f; // -0x1.bf2000p-1
	const float n1 = -2.76107788e-2f; // -0x1.c46000p-6
	const float d0 =  2.79589844e+0f; //  0x1.65e000p+1

	auto x_next0 = *inIt++;
	auto x_next1 = *inIt++;
	for (int i = 0; i < H*W / VECTOR_SIZE / 2 - 1; ++i)
#ifdef DIRECTIVE
		chess_prepare_for_pipelining
#endif
	{
		auto x0 = x_next0;
		auto x1 = x_next1;
		x_next0 = *inIt++;
		x_next1 = *inIt++;

		aie::accum<accfloat, VECTOR_SIZE> n1_acc;
		n1_acc.from_vector(aie::broadcast<float, VECTOR_SIZE>(n1));
		auto x0_sqr = aie::mul(x0, x0).to_vector();
		auto x1_sqr = aie::mul(x1, x1).to_vector();
		auto num0 = aie::mac(n1_acc, x0_sqr, n0).to_vector();
		auto num1 = aie::mac(n1_acc, x1_sqr, n0).to_vector();
		auto den0 = aie::add(x0_sqr, d0);
		auto den1 = aie::add(x1_sqr, d0);
		auto quot0 = aie::mul(num0, aie::inv(den0)).to_vector();
		auto quot1 = aie::mul(num1, aie::inv(den1)).to_vector();
		aie::accum<accfloat, VECTOR_SIZE> acc0;
		aie::accum<accfloat, VECTOR_SIZE> acc1;
		acc0.from_vector(x0);
		acc1.from_vector(x1);
		auto res0 = aie::mac(acc0, quot0, x0).to_vector();
		auto res1 = aie::mac(acc1, quot1, x1).to_vector();
		res0 = aie::max(res0, -1.0f);
		res1 = aie::max(res1, -1.0f);
		res0 = aie::min(res0, 1.0f);
		res1 = aie::min(res1, 1.0f);
		*outIt++ = res0;
		*outIt++ = res1;
	}

	// last iteration
	auto x0 = x_next0;
	auto x1 = x_next1;

	aie::accum<accfloat, VECTOR_SIZE> n1_acc;
	n1_acc.from_vector(aie::broadcast<float, VECTOR_SIZE>(n1));
	auto x0_sqr = aie::mul(x0, x0).to_vector();
	auto x1_sqr = aie::mul(x1, x1).to_vector();
	auto num0 = aie::mac(n1_acc, x0_sqr, n0).to_vector();
	auto num1 = aie::mac(n1_acc, x1_sqr, n0).to_vector();
	auto den0 = aie::add(x0_sqr, d0);
	auto den1 = aie::add(x1_sqr, d0);
	auto quot0 = aie::mul(num0, aie::inv(den0)).to_vector();
	auto quot1 = aie::mul(num1, aie::inv(den1)).to_vector();
	aie::accum<accfloat, VECTOR_SIZE> acc0;
	aie::accum<accfloat, VECTOR_SIZE> acc1;
	acc0.from_vector(x0);
	acc1.from_vector(x1);
	auto res0 = aie::mac(acc0, quot0, x0).to_vector();
	auto res1 = aie::mac(acc1, quot1, x1).to_vector();
	res0 = aie::max(res0, -1.0f);
	res1 = aie::max(res1, -1.0f);
	res0 = aie::min(res0, 1.0f);
	res1 = aie::min(res1, 1.0f);
	*outIt++ = res0;
	*outIt++ = res1;
}
