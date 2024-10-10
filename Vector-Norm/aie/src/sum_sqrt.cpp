#include "kernels.h"
#include <adf.h>
#include <aie_api/aie.hpp>

void sum_sqrt_kernel(adf::input_buffer<float, adf::extents<WINDOW_SIZE>> &in_x, adf::input_buffer<float, adf::extents<WINDOW_SIZE>> &in_y,
		adf::output_buffer<float, adf::extents<WINDOW_SIZE>> &out) {
	auto inXIt = aie::cbegin_vector<VECTOR_SIZE>(in_x);
	auto inYIt = aie::cbegin_vector<VECTOR_SIZE>(in_y);
	auto outIt = aie::begin_vector<VECTOR_SIZE>(out);

	for (int i = 0; i < WINDOW_SIZE / VECTOR_SIZE; ++i) {
		auto inX_i = *inXIt++;
		auto inY_i =*inYIt++;
		*outIt++ = aie::sqrt(aie::add(inX_i, inY_i));
	}
}
