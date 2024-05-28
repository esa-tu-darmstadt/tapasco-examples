#include "joiner.h"
#include <adf.h>
#include <aie_api/aie.hpp>
#include <aie_api/aie_adf.hpp>


template<size_t H, size_t W>
void join_supertiles(input_buffer<float, adf::extents<H*W>> & left_in, input_buffer<float, adf::extents<H*W>> & right_in, output_buffer<float, adf::extents<2*H*W>> & concat_out) {
	auto v_left = aie::begin_vector<16>(left_in);
	auto v_right = aie::begin_vector<16>(right_in);
	auto v_out = aie::begin_vector<16>(concat_out);

	// 4x4 tiles => W / 4 tiles per tile row
	// H / 4 tiles per tile column
	// every W / 4 reads we need to switch the input

	decltype(v_left) iterators[2] = {v_left, v_right};
	constexpr uint32 n_tile_cols = W / 4;
	constexpr uint32 n_tile_rows = H / 4;

	for(int i = 0; i < n_tile_rows; i++) {
		for(int j = 0; j < 2; j++)
		chess_prepare_for_pipelining
		{
			auto curr = iterators[j];
			for(int k = 0; k < n_tile_cols; k++)
			chess_prepare_for_pipelining
			{
				auto vec = *curr++;
				*v_out++ = vec;
			}
		}
	}
}

