#pragma once

#include <aie_api/aie.hpp>

#define TILE_WIDTH 4
#define VECTOR_SIZE 8

template<size_t B_SZ>
class MatVecMultFirst {
private:
	float (&_weights)[16];

public:
	MatVecMultFirst(float (&weights)[16]);

	void matVecMult_first(adf::input_buffer<float, adf::extents<B_SZ * 16>> &in,
			output_stream<accfloat> *outCascade);

	static void registerKernelClass() {
		REGISTER_FUNCTION(MatVecMultFirst::matVecMult_first);
		REGISTER_PARAMETER(_weights);
	}
};

template<size_t B_SZ, int OFFSET>
class MatVecMultMiddle {
private:
	float (&_weights)[16];

public:
	MatVecMultMiddle(float (&weights)[16]);

	void matVecMult_middle(adf::input_buffer<float, adf::extents<B_SZ * 16>> &in,
			input_stream<accfloat> *inCascade,
			output_stream<accfloat> *outCascade);

	static void registerKernelClass() {
		REGISTER_FUNCTION(MatVecMultMiddle::matVecMult_middle);
		REGISTER_PARAMETER(_weights);
	}
};

template<size_t B_SZ>
class MatVecMultLast {
private:
	float (&_weights)[16];

public:
	MatVecMultLast(float (&weights)[16]);

	void matVecMult_last(adf::input_buffer<float,adf::extents<B_SZ * 16>> &in,
			input_stream<accfloat> *inCascade,
			adf::output_buffer<float, adf::extents<B_SZ * 16>> &out);

	static void registerKernelClass() {
		REGISTER_FUNCTION(MatVecMultLast::matVecMult_last);
		REGISTER_PARAMETER(_weights);
	}
};

//template<size_t B_SZ>
//void matVecMult_last(input_stream<accfloat> *inCascade,
//		adf::output_buffer<float, adf::extents<B_SZ>> &out);

template<size_t B_SZ>
void matVecMult_reorder(adf::input_buffer<float, adf::extents<B_SZ * 16>> &in,
		adf::output_buffer<float, adf::extents<B_SZ * 16>> &out);

template<size_t B_SZ>
void matVecMult_acc(adf::input_buffer<float, adf::extents<B_SZ * 16>> &in,
		adf::output_buffer<float, adf::extents<B_SZ>> &out);


//template<size_t B_SZ>
//void matVecMult_reorder(input_stream<accfloat> *inCascade,
//		output_stream<accfloat> *outCascade);

//template<size_t B_SZ>
//void matVecMult_acc(input_stream<accfloat> *inCascade,
//		adf::output_buffer<float, adf::extents<B_SZ>> &out);

template<size_t B_SZ>
class MatVecMultBiasAdd {
private:
	float _bias;

public:
	MatVecMultBiasAdd(float bias);

	void matVecMult_bias(adf::input_buffer<float, adf::extents<B_SZ>> &in,
			adf::output_buffer<float, adf::extents<B_SZ>> &out);

	static void registerKernelClass() {
		REGISTER_FUNCTION(MatVecMultBiasAdd::matVecMult_bias);
	}
};

