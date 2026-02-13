#include <adf.h>
#include "layers.h"
#include "luts.h"
#include "kernels/joiner.h"
#include "matVecMultGraph.h"
#include "kernels/feature_split.h"
#include "kernels/result_join.h"

#define DIM_A (BATCH_SIZE / SPLIT)
#define DIM_AB (W0_H)
#define DIM_B (W0_W / SPLIT)

#define WINDOW_SIZE_A (DIM_A * DIM_AB)
#define WINDOW_SIZE_B (DIM_AB * DIM_B)

class MyGraph: public adf::graph {
public:
	port<input> weights0[SPLIT0 * CASC_LN0];
	port<input> weights1[SPLIT1 * CASC_LN1];
	port<input> weights2[SPLIT2 * CASC_LN2];
	port<input> features0[CASC_LN0];
	port<output> result;

//	adf::input_plio features0[CASC_LN0];
	//adf::input_plio features1[CASC_LN1];
	//adf::input_plio features2[CASC_LN2];
//	adf::input_plio weights0[(SPLIT0 * CASC_LN0)];
//	adf::input_plio weights1[(SPLIT1 * CASC_LN1)];
//	adf::input_plio weights2[(SPLIT2 * CASC_LN2)];
	//adf::input_plio weights3[(SPLIT3*CASC_LN3)];
	//adf::output_plio hidden0[SPLIT0];
	//adf::output_plio hidden1[SPLIT1];
//	adf::output_plio hidden2[SPLIT2];
//	adf::output_plio result;

	Layer<W0_H, W0_W, SPLIT0, CASC_LN0> layer0;
	Layer<W1_H, W1_W, SPLIT1, CASC_LN1> layer1;
	Layer<W2_H, W2_W, SPLIT2, CASC_LN2> layer2;
	//Layer<W3_H, W3_W, SPLIT3, CASC_LN3> layer3;

	MatVecMultGraph<BATCH_SIZE / SPLIT2> matVecMult;

	adf::kernel joiner[4]; // in the current SPLIT/CASC_LN configuration we only need joiners for the first layer

	MyGraph() : layer0(luts_0), layer1(luts_1), layer2(luts_2), matVecMult(weights_3, luts_3[0][0]) {

		//xf::dsp::aie::blas::matrix_mult::matrix_mult_graph<float, float, DIM_A, DIM_AB, DIM_B, 0, 0, \
        //    ROW_MAJOR, ROW_MAJOR, ROW_MAJOR, 0, 0, 0, WINDOW_SIZE_A, WINDOW_SIZE_B, CASC_LN> mmult[SPLIT];

		/*layer0 = Layer<W0_H, W0_W, SPLIT0, CASC_LN0>(luts_0);
		layer1 = Layer<W1_H, W1_W, SPLIT1, CASC_LN1>(luts_1);
		layer2 = Layer<W2_H, W2_W, SPLIT2, CASC_LN2>(luts_2);
*/
		/* LAYER 0 */
		for (int j = 0; j < CASC_LN0; j++) {
//			std::string features_str = "Features0In_CASC_"
//					+ std::to_string(j);
//			std::string filename = "data/inputs/" + features_str + ".txt";
//			features0[j] = adf::input_plio::create(features_str.c_str(),
//					adf::plio_128_bits, filename.c_str());
//			adf::connect<>(features0[j].out[0], layer0.feature_inp[j]);
			adf::connect(features0[j], layer0.feature_inp[j]);
		}

		for (int i = 0; i < SPLIT0; i++) {
			//adf::kernel* kernels = mmult[i].getKernels();

			for (int j = 0; j < CASC_LN0; j++) {
				//adf::runtime<ratio>(kernels[j]) = 0.8;
				std::string weights_str = "Weights0In"
						+ std::to_string(i) + "_CASC_" + std::to_string(j);
				std::string filename = "data/inputs/" +  weights_str + ".txt";
//				weights0[i * CASC_LN0 + j] = adf::input_plio::create(
//						weights_str.c_str(), adf::plio_128_bits,
//						filename.c_str());

//				adf::connect<>(weights0[i * CASC_LN0 + j].out[0],
//						layer0.weight_inp[i * CASC_LN0 + j]);
				adf::connect(weights0[i * CASC_LN0 +j], layer0.weight_inp[i * CASC_LN0 + j]);
				//adf::connect<>(features[j].out[0], mmult[i].inA[j]);
				//adf::connect<>(weights[i*CASC_LN+j].out[0], mmult[i].inB[j]);
			}
/*
			std::string hidden_str = "data/outputs/Hidden0Out"
					+ std::to_string(i);
			std::string hidden_file = hidden_str + ".txt";
			hidden0[i] = adf::output_plio::create(hidden_str.c_str(),
					adf::plio_128_bits, hidden_file.c_str());*/
			//adf::connect<>(layer0.out[i], hidden0[i].in[0]);
			//adf::connect<>(mmult[i].out, hidden[i].in[0]);
		}
		// Connect the 8 outputs of layer 0 to the join kernels and connect their outputs to the inputs of the next layer
		for(int i = 0; i < CASC_LN1; i++) {
			joiner[i] = adf::kernel::create(join_supertiles<BATCH_SIZE / SPLIT0, W0_W / SPLIT0>);
			adf::source(joiner[i]) = "kernels/joiner.cc";
			adf::runtime<ratio>(joiner[i]) = 0.8;
			adf::connect<>(layer0.out[2*i], joiner[i].in[0]);
			adf::connect<>(layer0.out[2*i+1], joiner[i].in[1]);
			adf::connect<>(joiner[i].out[0], layer1.feature_inp[i]);
		}

		/* LAYER 1 */
		/*
		for (int j = 0; j < CASC_LN1; j++) {
			std::string features_str = "data/inputs/Features1In_CASC_"
					+ std::to_string(j);
			std::string filename = features_str + ".txt";
			features1[j] = adf::input_plio::create(features_str.c_str(),
					adf::plio_128_bits, filename.c_str());
			adf::connect<>(features1[j].out[0], layer1.feature_inp[j]);
		}*/

		for (int i = 0; i < SPLIT1; i++) {
			for (int j = 0; j < CASC_LN1; j++) {
				std::string weights_str = "Weights1In"
						+ std::to_string(i) + "_CASC_" + std::to_string(j);
				std::string filename = "data/inputs/" + weights_str + ".txt";
//				weights1[i * CASC_LN1 + j] = adf::input_plio::create(
//						weights_str.c_str(), adf::plio_128_bits,
//						filename.c_str());

//				adf::connect<>(weights1[i * CASC_LN1 + j].out[0],
//						layer1.weight_inp[i * CASC_LN1 + j]);
				adf::connect<>(weights1[i * CASC_LN1 + j], layer1.weight_inp[i * CASC_LN1 + j]);
			}
/*
			std::string hidden_str = "data/outputs/Hidden1Out"
					+ std::to_string(i);
			std::string hidden_file = hidden_str + ".txt";
			hidden1[i] = adf::output_plio::create(hidden_str.c_str(),
					adf::plio_128_bits, hidden_file.c_str());
			adf::connect<>(layer1.out[i], hidden1[i].in[0]);*/
			adf::connect<>(layer1.out[i], layer2.feature_inp[i]);
		}

		/* LAYER 2 */
		for (int j = 0; j < CASC_LN2; j++) {
			/*
			std::string features_str = "data/inputs/Features2In_CASC_"
					+ std::to_string(j);
			std::string filename = features_str + ".txt";
			features2[j] = adf::input_plio::create(features_str.c_str(),
					adf::plio_128_bits, filename.c_str());
			adf::connect<>(features2[j].out[0], layer2.feature_inp[j]);*/
		}

		for (int i = 0; i < SPLIT2; i++) {
			for (int j = 0; j < CASC_LN2; j++) {
				std::string weights_str = "Weights2In"
						+ std::to_string(i) + "_CASC_" + std::to_string(j);
				std::string filename = "data/inputs/" + weights_str + ".txt";
//				weights2[i * CASC_LN2 + j] = adf::input_plio::create(
//						weights_str.c_str(), adf::plio_128_bits,
//						filename.c_str());

//				adf::connect<>(weights2[i * CASC_LN1 + j].out[0],
//						layer2.weight_inp[i * CASC_LN1 + j]);
				adf::connect<>(weights2[i * CASC_LN2 + j], layer2.weight_inp[i * CASC_LN2 + j]);
			}

			std::string hidden_str = "data/outputs/Hidden2Out"
					+ std::to_string(i);
			std::string hidden_file = hidden_str + ".txt";
//			hidden2[i] = adf::output_plio::create(hidden_str.c_str(),
//					adf::plio_128_bits, hidden_file.c_str());
//			adf::connect<>(layer2.out[i], hidden2[i].in[0]);
		}

		/* Layer 3 */
//		result = adf::output_plio::create(plio_128_bits, "data/outputs/result.txt");
		for (int i = 0; i < 4; ++i) {
			adf::connect<>(layer2.out[i], matVecMult.matrix_in[i]);
		}
//		adf::connect<>(matVecMult.result, result.in[0]);
		adf::connect(matVecMult.result, result);
	}
};

class TopGraph: public adf::graph {
private:
	kernel split_kernels[4];
	kernel join_kernel;
public:
	adf::input_plio features0[CASC_LN0];
	adf::input_plio weights0[(SPLIT0 * CASC_LN0)];
	adf::input_plio weights1[(SPLIT1 * CASC_LN1)];
	adf::input_plio weights2[(SPLIT2 * CASC_LN2)];
	adf::output_plio result;

	MyGraph graph0;
	MyGraph graph1;

	TopGraph() {
		/* LAYER 0 */
		for (int j = 0; j < CASC_LN0; j++) {
			split_kernels[j] = kernel::create(feature_split<BATCH_SIZE / CASC_LN0 * W0_H>);
			std::string features_str = "Features0In_CASC_"
					+ std::to_string(j);
			std::string filename = "data/inputs/" + features_str + ".txt";
			features0[j] = adf::input_plio::create(features_str.c_str(),
					adf::plio_128_bits, filename.c_str());
//			adf::connect<>(features0[j].out[0], graph0.features0[j]);
			adf::connect(features0[j].out[0], split_kernels[j].in[0]);
			adf::connect(split_kernels[j].out[0], graph0.features0[j]);
			adf::connect(split_kernels[j].out[1], graph1.features0[j]);
		}

		for (int i = 0; i < SPLIT0; i++) {
			for (int j = 0; j < CASC_LN0; j++) {
				std::string weights_str = "Weights0In"
						+ std::to_string(i) + "_CASC_" + std::to_string(j);
				std::string filename = "data/inputs/" +  weights_str + ".txt";
				weights0[i * CASC_LN0 + j] = adf::input_plio::create(
						weights_str.c_str(), adf::plio_128_bits,
						filename.c_str());

				adf::connect(weights0[i * CASC_LN0 +j].out[0], graph0.weights0[i * CASC_LN0 + j]);
				adf::connect(weights0[i * CASC_LN0 +j].out[0], graph1.weights0[i * CASC_LN0 + j]);
			}
		}

		/* LAYER 1 */
		for (int i = 0; i < SPLIT1; i++) {
			for (int j = 0; j < CASC_LN1; j++) {
				std::string weights_str = "Weights1In"
						+ std::to_string(i) + "_CASC_" + std::to_string(j);
				std::string filename = "data/inputs/" + weights_str + ".txt";
				weights1[i * CASC_LN1 + j] = adf::input_plio::create(
						weights_str.c_str(), adf::plio_128_bits,
						filename.c_str());

				adf::connect<>(weights1[i * CASC_LN1 + j].out[0], graph0.weights1[i * CASC_LN1 + j]);
				adf::connect<>(weights1[i * CASC_LN1 + j].out[0], graph1.weights1[i * CASC_LN1 + j]);
			}
		}

		/* LAYER 2 */
		for (int i = 0; i < SPLIT2; i++) {
			for (int j = 0; j < CASC_LN2; j++) {
				std::string weights_str = "Weights2In"
						+ std::to_string(i) + "_CASC_" + std::to_string(j);
				std::string filename = "data/inputs/" + weights_str + ".txt";
				weights2[i * CASC_LN2 + j] = adf::input_plio::create(
						weights_str.c_str(), adf::plio_128_bits,
						filename.c_str());

				adf::connect<>(weights2[i * CASC_LN2 + j].out[0], graph0.weights2[i * CASC_LN2 + j]);
				adf::connect<>(weights2[i * CASC_LN2 + j].out[0], graph1.weights2[i * CASC_LN2 + j]);
			}
		}

		/* Layer 3 */
		join_kernel = kernel::create(result_join<BATCH_SIZE>);
		result = adf::output_plio::create(plio_128_bits, "data/outputs/result.txt");
//		adf::connect(graph0.result, result.in[0]);
		adf::connect(graph0.result, join_kernel.in[0]);
		adf::connect(graph1.result, join_kernel.in[1]);
		adf::connect(join_kernel.out[0], result.in[0]);

		for (int j = 0; j < 4; ++j){
			runtime<ratio>(split_kernels[j]) = 0.9;
			source(split_kernels[j]) = "kernels/feature_split.cpp";
		}
		runtime<ratio>(join_kernel) = 0.9;
		source(join_kernel) = "kernels/result_join.cpp";
	}
};
