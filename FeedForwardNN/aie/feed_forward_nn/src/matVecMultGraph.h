#pragma once

#include <adf.h>
#include "kernels/matVecMult.hpp"
#include "kernels/bias.h"

using namespace adf;

template<size_t B_SZ>
class MatVecMultGraph : public graph {
private:
	//kernel kernels[5];
	kernel kernels[6];
	kernel bias_kernel;

public:
	port<input> matrix_in[4];
	port<output> result;

	MatVecMultGraph(float (&weights)[64], float bias) {
		kernels[0] = kernel::create_object<MatVecMultFirst<B_SZ>>(std::vector<float>(&weights[0], &weights[16]));
		kernels[1] = kernel::create_object<MatVecMultMiddle<B_SZ, 1>>(std::vector<float>(&weights[16], &weights[32]));
		kernels[2] = kernel::create_object<MatVecMultMiddle<B_SZ, 2>>(std::vector<float>(&weights[32], &weights[48]));
		//kernels[3] = kernel::create_object<MatVecMultMiddle<B_SZ, 3>>(std::vector<float>(&weights[48], &weights[64]));
		kernels[3] = kernel::create_object<MatVecMultLast<B_SZ>>(std::vector<float>(&weights[48], &weights[64]));
		//kernels[4] = kernel::create(matVecMult_last<B_SZ>);
		kernels[4] = kernel::create(matVecMult_reorder<B_SZ>);
		kernels[5] = kernel::create(matVecMult_acc<B_SZ>);
		bias_kernel = kernel::create_object<MatVecMultBiasAdd<B_SZ>>(bias);

		for (int i = 0; i < 4; ++i) {
			connect(matrix_in[i], kernels[i].in[0]);
			if (i > 0) {
				connect<cascade>(kernels[i - 1].out[0], kernels[i].in[1]);
			}
		}
		//connect<cascade>(kernels[3].out[0], kernels[4].in[0]);
		connect(kernels[3].out[0], kernels[4].in[0]);
		//connect(kernels[4].out[0], bias_kernel.in[0]);
		//connect<cascade>(kernels[4].out[0], kernels[5].in[0]);
		connect(kernels[4].out[0], kernels[5].in[0]);
		connect(kernels[5].out[0], bias_kernel.in[0]);
		connect(bias_kernel.out[0], result);

		//for (int i = 0; i < 5; ++i) {
		for (int i = 0; i < 6; ++i) {
			runtime<ratio>(kernels[i]) = 0.8;
			if (i == 0) {
				source(kernels[i]) = "kernels/matVecMult_first.cpp";
			} else if (i == 3) {
				source(kernels[i]) = "kernels/matVecMult_last.cpp";
			} else if (i == 4) {
				//source(kernels[i]) = "kernels/matVecMult_last.cpp";
				source(kernels[i]) = "kernels/matVecMult_reorder.cpp";
			} else if (i == 5) {
				source(kernels[i]) = "kernels/matVecMult_acc.cpp";
			} else { // i == 6
				source(kernels[i]) = "kernels/matVecMult_middle.cpp";
			}
		}
		runtime<ratio>(bias_kernel) = 0.8;
		source(bias_kernel) = "kernels/matVecMult_bias.cpp";
	}
};
