#include "matVecMult.hpp"

template<size_t B_SZ>
MatVecMultLast<B_SZ>::MatVecMultLast(float (&weights)[16]) : _weights(weights) {};

template<size_t B_SZ>
void MatVecMultLast<B_SZ>::matVecMult_last(adf::input_buffer<float, adf::extents<B_SZ * 16>> &in,
		input_stream<accfloat> *inCascade,
		adf::output_buffer<float, adf::extents<B_SZ * 16>> &out) {
	auto inIt = aie::cbegin_vector<VECTOR_SIZE>(in);
	auto outIt = aie::begin_vector<VECTOR_SIZE>(out);
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

			*outIt++ = p0.to_vector();
			*outIt++ = p1.to_vector();
		}
	}

}


//template<size_t B_SZ>
//void matVecMult_last(input_stream<accfloat> *cascIn,
//		adf::output_buffer<float, adf::extents<B_SZ>> &out) {
//	auto outIt = aie::begin_vector<TILE_WIDTH>(out);
//
//	for (int i = 0; i < B_SZ / 4; ++i) {
//		aie::vector<float, TILE_WIDTH> tmp_vec[4];
//		aie::vector<float, VECTOR_SIZE> tmp = readincr_v<VECTOR_SIZE>(cascIn);
//		tmp_vec[0] = tmp.template extract<TILE_WIDTH>(0);
//		tmp_vec[1] = tmp.template extract<TILE_WIDTH>(1);
//		tmp = readincr_v<VECTOR_SIZE>(cascIn);
//		tmp_vec[2] = tmp.template extract<TILE_WIDTH>(0);
//		tmp_vec[3] = tmp.template extract<TILE_WIDTH>(1);
//
//		aie::vector<float, VECTOR_SIZE> v[4];
//		tmp = readincr_v<VECTOR_SIZE>(cascIn);
//		v[0] = aie::concat(tmp_vec[0], tmp.template extract<TILE_WIDTH>(0));
//		v[1] = aie::concat(tmp_vec[1], tmp.template extract<TILE_WIDTH>(1));
//		tmp = readincr_v<VECTOR_SIZE>(cascIn);
//		v[2] = aie::concat(tmp_vec[2], tmp.template extract<TILE_WIDTH>(0));
//		v[3] = aie::concat(tmp_vec[3], tmp.template extract<TILE_WIDTH>(1));
//
//		auto sums = aie::reduce_add_v(v[0], v[1], v[2], v[3]);
//		aie::vector<float, TILE_WIDTH> sums_acc = sums.template extract<TILE_WIDTH>(0);
//
//		tmp = readincr_v<VECTOR_SIZE>(cascIn);
//		tmp_vec[0] = tmp.template extract<TILE_WIDTH>(0);
//		tmp_vec[1] = tmp.template extract<TILE_WIDTH>(1);
//		tmp = readincr_v<VECTOR_SIZE>(cascIn);
//		tmp_vec[2] = tmp.template extract<TILE_WIDTH>(0);
//		tmp_vec[3] = tmp.template extract<TILE_WIDTH>(1);
//
//		tmp = readincr_v<VECTOR_SIZE>(cascIn);
//		v[0] = aie::concat(tmp_vec[0], tmp.template extract<TILE_WIDTH>(0));
//		v[1] = aie::concat(tmp_vec[1], tmp.template extract<TILE_WIDTH>(1));
//		tmp = readincr_v<VECTOR_SIZE>(cascIn);
//		v[2] = aie::concat(tmp_vec[2], tmp.template extract<TILE_WIDTH>(0));
//		v[3] = aie::concat(tmp_vec[3], tmp.template extract<TILE_WIDTH>(1));
//
//		sums = aie::reduce_add_v(v[0], v[1], v[2], v[3]);
//		sums_acc = aie::add(sums_acc, sums.template extract<TILE_WIDTH>(0));
//
//		*outIt++ = sums_acc;
//	}
//}
