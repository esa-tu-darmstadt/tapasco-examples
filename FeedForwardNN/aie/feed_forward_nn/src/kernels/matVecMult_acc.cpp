#include "matVecMult.hpp"

template<size_t B_SZ>
void matVecMult_acc(adf::input_buffer<float, adf::extents<B_SZ * 16>> &in,
		adf::output_buffer<float, adf::extents<B_SZ>> &out) {
	auto inIt = aie::cbegin_vector<VECTOR_SIZE>(in);
	auto outIt = aie::begin_vector<TILE_WIDTH>(out);

	for (int i = 0; i < B_SZ / 4; ++i) {
		aie::vector<float, VECTOR_SIZE> v[4];
		for (int k = 0; k < 4; ++k) {
			v[k] = *inIt++;
		}
		auto sums = aie::reduce_add_v(v[0], v[1], v[2], v[3]);
		aie::vector<float, TILE_WIDTH> sums_acc = sums.template extract<TILE_WIDTH>(0);

		for (int k = 0; k < 4; ++k) {
			v[k] = *inIt++;
		}
		sums = aie::reduce_add_v(v[0], v[1], v[2], v[3]);
		sums_acc = aie::add(sums_acc, sums.template extract<TILE_WIDTH>(0));

		*outIt++ = sums_acc;
	}
}

//template<size_t B_SZ>
//void matVecMult_acc(input_stream<accfloat> *cascadeIn,
//		adf::output_buffer<float, adf::extents<B_SZ>> &out) {
//	auto outIt = aie::begin_vector<TILE_WIDTH>(out);
//
//	for (int i = 0; i < B_SZ / 4; ++i) {
//		aie::vector<float, TILE_WIDTH> tmp_vec[4];
////		aie::vector<float, VECTOR_SIZE> tmp = readincr_v<VECTOR_SIZE>(cascIn);
////		tmp_vec[0] = tmp.template extract<TILE_WIDTH>(0);
////		tmp_vec[1] = tmp.template extract<TILE_WIDTH>(1);
////		tmp = readincr_v<VECTOR_SIZE>(cascIn);
////		tmp_vec[2] = tmp.template extract<TILE_WIDTH>(0);
////		tmp_vec[3] = tmp.template extract<TILE_WIDTH>(1);
////
//		aie::vector<float, VECTOR_SIZE> v[4];
////		tmp = readincr_v<VECTOR_SIZE>(cascIn);
////		v[0] = aie::concat(tmp_vec[0], tmp.template extract<TILE_WIDTH>(0));
////		v[1] = aie::concat(tmp_vec[1], tmp.template extract<TILE_WIDTH>(1));
////		tmp = readincr_v<VECTOR_SIZE>(cascIn);
////		v[2] = aie::concat(tmp_vec[2], tmp.template extract<TILE_WIDTH>(0));
////		v[3] = aie::concat(tmp_vec[3], tmp.template extract<TILE_WIDTH>(1));
//
//		for (int k = 0; k < 4; ++k) {
//			v[k] = readincr_v<VECTOR_SIZE>(cascadeIn);
//		}
//
//		auto sums = aie::reduce_add_v(v[0], v[1], v[2], v[3]);
//		aie::vector<float, TILE_WIDTH> sums_acc = sums.template extract<TILE_WIDTH>(0);
//
////		tmp = readincr_v<VECTOR_SIZE>(cascIn);
////		tmp_vec[0] = tmp.template extract<TILE_WIDTH>(0);
////		tmp_vec[1] = tmp.template extract<TILE_WIDTH>(1);
////		tmp = readincr_v<VECTOR_SIZE>(cascIn);
////		tmp_vec[2] = tmp.template extract<TILE_WIDTH>(0);
////		tmp_vec[3] = tmp.template extract<TILE_WIDTH>(1);
////
////		tmp = readincr_v<VECTOR_SIZE>(cascIn);
////		v[0] = aie::concat(tmp_vec[0], tmp.template extract<TILE_WIDTH>(0));
////		v[1] = aie::concat(tmp_vec[1], tmp.template extract<TILE_WIDTH>(1));
////		tmp = readincr_v<VECTOR_SIZE>(cascIn);
////		v[2] = aie::concat(tmp_vec[2], tmp.template extract<TILE_WIDTH>(0));
////		v[3] = aie::concat(tmp_vec[3], tmp.template extract<TILE_WIDTH>(1));
//
//		for (int k = 0; k < 4; ++k) {
//			v[k] = readincr_v<VECTOR_SIZE>(cascadeIn);
//		}
//		sums = aie::reduce_add_v(v[0], v[1], v[2], v[3]);
//		sums_acc = aie::add(sums_acc, sums.template extract<TILE_WIDTH>(0));
//
//		*outIt++ = sums_acc;
//	}
//}
