#pragma once

#include <aie_api/aie.hpp>

template<size_t B_SZ>
void feature_split(adf::input_buffer<float, adf::extents<B_SZ * 2>> &in,
		adf::output_buffer<float, adf::extents<B_SZ>> &out_0,
		adf::output_buffer<float, adf::extents<B_SZ>> &out_1);
