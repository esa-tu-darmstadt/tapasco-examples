#pragma once

#include "adf.h"
#include "kernels.h"

using namespace adf;

class vecNormGraph : public graph {
private:
	kernel square_k[2];
	kernel sum_sqrt_k;

public:
	input_plio in_x, in_y;
	output_plio out_z;

	vecNormGraph() {
		in_x = input_plio::create("in_x", plio_128_bits, "data/in_x.txt");
		in_y = input_plio::create("in_y", plio_128_bits, "data/in_y.txt");
		out_z = output_plio::create("out_z", plio_128_bits, "data/out_z.txt");

		for (int i = 0; i < 2; ++i) {
			square_k[i] = kernel::create(square_kernel);
			source(square_k[i]) = "square.cpp";
			runtime<ratio>(square_k[i]) = 1;
		}
		sum_sqrt_k = kernel::create(sum_sqrt_kernel);
		source(sum_sqrt_k) =  "sum_sqrt.cpp";
		runtime<ratio>(sum_sqrt_k) = 1;

		connect(in_x.out[0], square_k[0].in[0]);
		connect(in_y.out[0], square_k[1].in[0]);
		connect(square_k[0].out[0], sum_sqrt_k.in[0]);
		connect(square_k[1].out[0], sum_sqrt_k.in[1]);
		connect(sum_sqrt_k.out[0], out_z.in[0]);
	}
};

