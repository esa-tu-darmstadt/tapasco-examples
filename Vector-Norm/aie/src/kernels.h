#pragma once

#include <adf.h>

#define WINDOW_SIZE 1024
#define VECTOR_SIZE 8

void square_kernel(adf::input_buffer<float, adf::extents<WINDOW_SIZE>> &in, adf::output_buffer<float, adf::extents<WINDOW_SIZE>> &out);
void sum_sqrt_kernel(adf::input_buffer<float, adf::extents<WINDOW_SIZE>> &in_x, adf::input_buffer<float, adf::extents<WINDOW_SIZE>> &in_y,
		adf::output_buffer<float, adf::extents<WINDOW_SIZE>> &out);
