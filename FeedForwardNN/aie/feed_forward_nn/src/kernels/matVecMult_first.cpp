#include "matVecMult.hpp"

#include <adf.h>

template<size_t B_SZ>
MatVecMultFirst<B_SZ>::MatVecMultFirst(float (&weights)[16]) : _weights(weights) {}

template<size_t B_SZ>
void MatVecMultFirst<B_SZ>::matVecMult_first(adf::input_buffer<float, adf::extents<B_SZ * 16>> &in,
		output_stream<accfloat> *outCascade) {
	auto inIt = aie::cbegin_vector<VECTOR_SIZE>(in);
	for (int i = 0; i < B_SZ / 4; ++i) {
		for (int k = 0; k < 4; ++k) {
			auto in0 = *inIt++;
			auto in1 = *inIt++;

			aie::vector<float, TILE_WIDTH> w0 = aie::load_v<TILE_WIDTH>(&_weights[k * TILE_WIDTH]);
			auto w0_d = aie::concat(w0, w0);

			auto p0 = aie::mul(in0, w0_d);
			auto p1 = aie::mul(in1, w0_d);

			writeincr(outCascade, p0);
			writeincr(outCascade, p1);
		}
	}
}
