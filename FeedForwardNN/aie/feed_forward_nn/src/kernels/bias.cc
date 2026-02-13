#include "bias.h"
#include <aie_api/aie.hpp>
#include <aie_api/aie_adf.hpp>
using namespace adf;

template<size_t H_SUPERTILE, size_t W_SUPERTILE> BiasAdd<H_SUPERTILE, W_SUPERTILE>::BiasAdd(float (&bias_w)[W_SUPERTILE]) : weights(bias_w) {
}

/*
 * Input 4x2 tiles
 * Outputs 4x4 tiles right now
 */
template <size_t H_SUPERTILE, size_t W_SUPERTILE> void BiasAdd<H_SUPERTILE, W_SUPERTILE>::bias_add(input_window<float>* in, output_window<float>* out) {
	constexpr uint32 total_adds = H_SUPERTILE * W_SUPERTILE;
	constexpr uint32 add_v8s = total_adds >> 3;
	aie::vector<float, 8> features;
	aie::vector<float, 16> bias_weights;
	aie::vector<float, 16> sum_vec;
	aie::vector<float, 8> left_tile;
	aie::vector<float, 16> joined_tile;
	bool select_flag = false;
	//float* wptr = weights;
	auto w_iter = aie::cbegin_vector_circular<4, W_SUPERTILE>(weights);

	for(int i = 0; i < add_v8s; i++)
	chess_prepare_for_pipelining
	{
		features = window_readincr_v<8>(in);
		select_flag = !select_flag;
		if(!select_flag) {
			auto pair = aie::interleave_zip(left_tile, features, 2);
			joined_tile = aie::concat(pair.first, pair.second);
			auto curr_4weights = *w_iter++;
			bias_weights = curr_4weights.template grow_replicate<16>();
			sum_vec = aie::add(joined_tile, bias_weights);
			window_writeincr(out, sum_vec);
		}
		else {
			left_tile = features;
		}
	}
}
