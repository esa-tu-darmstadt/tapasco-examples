#include "matVecMult.hpp"

template<size_t B_SZ>
void matVecMult_reorder(adf::input_buffer<float, adf::extents<B_SZ * 16>> &in,
		adf::output_buffer<float, adf::extents<B_SZ * 16>> &out) {
	auto inIt = aie::cbegin_vector<VECTOR_SIZE>(in);
	auto outIt = aie::begin_vector<VECTOR_SIZE>(out);
	for (int i = 0; i < B_SZ / 2; ++i) {
		aie::vector<float, TILE_WIDTH> tmp_vec[4];
		aie::vector<float, VECTOR_SIZE> tmp = *inIt++;
		tmp_vec[0] = tmp.template extract<TILE_WIDTH>(0);
		tmp_vec[1] = tmp.template extract<TILE_WIDTH>(1);
		tmp = *inIt++;
		tmp_vec[2] = tmp.template extract<TILE_WIDTH>(0);
		tmp_vec[3] = tmp.template extract<TILE_WIDTH>(1);

		aie::vector<float, VECTOR_SIZE> v[4];
		tmp = *inIt++;
		v[0] = aie::concat(tmp_vec[0], tmp.template extract<TILE_WIDTH>(0));
		v[1] = aie::concat(tmp_vec[1], tmp.template extract<TILE_WIDTH>(1));
		tmp = *inIt++;
		v[2] = aie::concat(tmp_vec[2], tmp.template extract<TILE_WIDTH>(0));
		v[3] = aie::concat(tmp_vec[3], tmp.template extract<TILE_WIDTH>(1));

		for (int k = 0; k < 4; ++k) {
			*outIt++ = v[k];
		}
	}
}

//template<size_t B_SZ>
//void matVecMult_reorder(input_stream<accfloat> *cascadeIn,
//		output_stream<accfloat> *cascadeOut) {
//
//	for (int i = 0; i < B_SZ / 2; ++i) {
//		aie::vector<float, TILE_WIDTH> tmp_vec[4];
//		aie::vector<float, VECTOR_SIZE> tmp = readincr_v<VECTOR_SIZE>(cascadeIn);
//		tmp_vec[0] = tmp.template extract<TILE_WIDTH>(0);
//		tmp_vec[1] = tmp.template extract<TILE_WIDTH>(1);
//		tmp = readincr_v<VECTOR_SIZE>(cascadeIn);
//		tmp_vec[2] = tmp.template extract<TILE_WIDTH>(0);
//		tmp_vec[3] = tmp.template extract<TILE_WIDTH>(1);
//
//		aie::vector<float, VECTOR_SIZE> v[4];
//		tmp = readincr_v<VECTOR_SIZE>(cascadeIn);
//		v[0] = aie::concat(tmp_vec[0], tmp.template extract<TILE_WIDTH>(0));
//		v[1] = aie::concat(tmp_vec[1], tmp.template extract<TILE_WIDTH>(1));
//		tmp = readincr_v<VECTOR_SIZE>(cascadeIn);
//		v[2] = aie::concat(tmp_vec[2], tmp.template extract<TILE_WIDTH>(0));
//		v[3] = aie::concat(tmp_vec[3], tmp.template extract<TILE_WIDTH>(1));
//
//		for (int k = 0; k < 4; ++k) {
//			aie::accum<accfloat, VECTOR_SIZE> a;
//			a.from_vector(v[k]);
//			writeincr(cascadeOut, a);
////			writeincr(cascadeOut, v[k]);
//		}
//	}
//}
