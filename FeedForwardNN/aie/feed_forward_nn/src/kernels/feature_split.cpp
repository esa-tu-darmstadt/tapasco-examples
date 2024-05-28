#include "feature_split.h"

#define VECTOR_SIZE 8

template<size_t B_SZ>
void feature_split(adf::input_buffer<float, adf::extents<B_SZ * 2>> &in,
		adf::output_buffer<float, adf::extents<B_SZ>> &out_0,
		adf::output_buffer<float, adf::extents<B_SZ>> &out_1) {
	auto inIt = aie::cbegin_vector<VECTOR_SIZE>(in);
	auto out0It = aie::begin_vector<VECTOR_SIZE>(out_0);
	auto out1It = aie::begin_vector<VECTOR_SIZE>(out_1);

	for (int i = 0; i < B_SZ / VECTOR_SIZE; ++i) {
		*out0It++  = *inIt++;
	}

	for (int i = 0; i < B_SZ / VECTOR_SIZE; ++i) {
		*out1It++ = *inIt++;
	}
}
