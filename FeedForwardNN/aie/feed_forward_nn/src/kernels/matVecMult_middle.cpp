#include "matVecMult.hpp"

template<size_t B_SZ, int OFFSET>
MatVecMultMiddle<B_SZ, OFFSET>::MatVecMultMiddle(float (&weights)[16]) : _weights(weights) {};

template<size_t B_SZ, int OFFSET>
void MatVecMultMiddle<B_SZ, OFFSET>::matVecMult_middle(adf::input_buffer<float, adf::extents<B_SZ * 16>> &in,
		input_stream<accfloat> *inCascade,
		output_stream<accfloat> *outCascade) {

	auto inIt = aie::cbegin_vector<VECTOR_SIZE>(in);

	for (int i = 0; i < B_SZ / 4; ++i) {
		for (int k = 0; k < 4; ++k) {
			auto in0 = *inIt++;
			auto in1 = *inIt++;
			auto cascIn0 = readincr_v<VECTOR_SIZE>(inCascade);
			auto cascIn1 = readincr_v<VECTOR_SIZE>(inCascade);

			aie::vector<float, TILE_WIDTH> w0 = aie::load_v<TILE_WIDTH>(&_weights[k * TILE_WIDTH]);
			auto w0_d = aie::concat(w0, w0);

			auto p0 = aie::mac(cascIn0, in0, w0_d);
			auto p1 = aie::mac(cascIn1, in1, w0_d);

			writeincr(outCascade, p0);
			writeincr(outCascade, p1);
		}
	}

}
