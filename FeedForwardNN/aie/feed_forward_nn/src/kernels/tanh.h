#pragma once

#include <aie_api/aie.hpp>

#define WLEN_BASE 4096
#define VECTOR_SIZE 8

//#define DIRECTIVE
template<size_t H, size_t W>
void mytanh(adf::input_buffer<float, adf::extents<H*W>> &in,
		adf::output_buffer<float, adf::extents<H*W>> &out);
