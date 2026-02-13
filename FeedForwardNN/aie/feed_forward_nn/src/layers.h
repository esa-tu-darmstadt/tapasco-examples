#ifndef _LAYERS_H_
#define _LAYERS_H_

#include <adf.h>
#include "matrix_mult_graph.hpp"
#include "kernels/bias.h"
#include "kernels/tanh.h"

#define SPLIT0 8
#define SPLIT1 4
#define SPLIT2 4
#define SPLIT3 1
#define BATCH_SIZE 32
//#define CASC_LN 4 // we can play with this for parallelization
#define CASC_LN0 4
#define CASC_LN1 4
#define CASC_LN2 4
#define CASC_LN3 1
#define N_SAMPLES 1 // leave this alone for now, batching is included in matrix dimensions
#define W0_H 64
#define W0_W 128
#define W1_H 128
#define W1_W 64
#define W2_H 64
#define W2_W 64
#define W3_H 64
#define W3_W 1

/* H = Height of weight matrix, W = width of weight matrix */
template<size_t H, size_t W, size_t SPLIT, size_t CASC_LN>
class Layer : public adf::graph
{
    public:
    adf::port<input> feature_inp[CASC_LN];
    adf::port<input> weight_inp[(SPLIT * CASC_LN)];
    adf::port<output> out[SPLIT];

    adf::kernel bias_adds[SPLIT];
    adf::kernel tanhs[SPLIT];

    xf::dsp::aie::blas::matrix_mult::matrix_mult_graph<float, float, BATCH_SIZE / SPLIT, H, W / SPLIT, 0, 0, \
                   ROW_MAJOR, ROW_MAJOR, ROW_MAJOR, 0, 0, 0, (BATCH_SIZE / SPLIT) * H, H * (W / SPLIT), CASC_LN> mmult[SPLIT];
    Layer(float (&bias_weights)[SPLIT][W / SPLIT]){
        for(int i = 0; i < SPLIT; i++) {
        	bias_adds[i] = adf::kernel::create_object<BiasAdd<BATCH_SIZE / SPLIT, W / SPLIT>>(std::vector<float>(&bias_weights[i][0], &bias_weights[i][W / SPLIT]));
        	adf::runtime<ratio>(bias_adds[i]) = 0.8;
        	adf::source(bias_adds[i]) = "kernels/bias.cc";

        	tanhs[i] = adf::kernel::create(mytanh<BATCH_SIZE / SPLIT, W / SPLIT>);
        	adf::runtime<ratio>(tanhs[i]) = 0.8;
        	adf::source(tanhs[i]) = "kernels/tanh.cpp";

            adf::kernel* kernels = mmult[i].getKernels();

            for(int k = 0; k < CASC_LN; k++) {
                adf::runtime<ratio>(kernels[k]) = 0.8;

                adf::connect<>(feature_inp[k], mmult[i].inA[k]);
                adf::connect<>(weight_inp[(i*CASC_LN)+k], mmult[i].inB[k]);
            }
            //adf::connect<>(mmult[i].out, out[i]);
            // connect matrix outputs to bias addition
            adf::connect<window<(BATCH_SIZE / SPLIT) * (W / SPLIT) * 4>>(mmult[i].out[0], bias_adds[i].in[0]);
            adf::connect<window<(BATCH_SIZE / SPLIT) * (W / SPLIT) * 4>>(bias_adds[i].out[0], tanhs[i].in[0]);
            adf::connect<>(tanhs[i].out[0], out[i]);
        }   
    }
};


#endif
