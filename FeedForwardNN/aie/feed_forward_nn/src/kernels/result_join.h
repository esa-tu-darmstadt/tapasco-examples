#pragma once

#include <aie_api/aie.hpp>

template<size_t B_SZ>
void result_join(adf::input_buffer<float, adf::extents<B_SZ>> &in_0,
		adf::input_buffer<float, adf::extents<B_SZ>> &in_1,
		adf::output_buffer<float, adf::extents<B_SZ * 2>> &out);
