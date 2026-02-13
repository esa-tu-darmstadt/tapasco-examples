#include "result_join.h"

#define VECTOR_SIZE 8

template<size_t B_SZ>
void result_join(adf::input_buffer<float, adf::extents<B_SZ>> &in_0,
		adf::input_buffer<float, adf::extents<B_SZ>> &in_1,
		adf::output_buffer<float, adf::extents<B_SZ * 2>> &out) {
	auto in0It = aie::cbegin_vector<VECTOR_SIZE>(in_0);
	auto in1It = aie::cbegin_vector<VECTOR_SIZE>(in_1);
	auto outIt = aie::begin_vector<VECTOR_SIZE>(out);

	for (int i = 0; i < B_SZ / VECTOR_SIZE; ++i) {
		*outIt++ = *in0It++;
	}

	for (int i = 0; i < B_SZ / VECTOR_SIZE; ++i) {
		*outIt++ = *in1It++;
	}
}
