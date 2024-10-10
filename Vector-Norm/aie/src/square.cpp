#include "kernels.h"
#include <adf.h>
#include <aie_api/aie.hpp>

void square_kernel(adf::input_buffer<float, adf::extents<WINDOW_SIZE>> &in, adf::output_buffer<float, adf::extents<WINDOW_SIZE>> &out) {
	auto inIt = aie::cbegin_vector<VECTOR_SIZE>(in);
	auto outIt = aie::begin_vector<VECTOR_SIZE>(out);

	for (int i = 0; i < WINDOW_SIZE / VECTOR_SIZE; ++i) {
		auto in_i = *inIt++;
		*outIt++ = aie::mul(in_i, in_i);
	}
}
