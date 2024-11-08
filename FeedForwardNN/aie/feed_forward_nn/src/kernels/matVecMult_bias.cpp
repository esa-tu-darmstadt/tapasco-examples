#include "matVecMult.hpp"

template<size_t B_SZ>
MatVecMultBiasAdd<B_SZ>::MatVecMultBiasAdd(float bias) : _bias(bias) {};

template<size_t B_SZ>
void MatVecMultBiasAdd<B_SZ>::matVecMult_bias(adf::input_buffer<float, adf::extents<B_SZ>> &in,
		adf::output_buffer<float, adf::extents<B_SZ>> &out) {
	auto inIt = aie::cbegin_vector<VECTOR_SIZE>(in);
	auto outIt = aie::begin_vector<VECTOR_SIZE>(out);
	for (int i = 0; i < B_SZ / VECTOR_SIZE; ++i) {
		auto v = *inIt++;
		*outIt++ = aie::add(v, _bias);
	}
}
