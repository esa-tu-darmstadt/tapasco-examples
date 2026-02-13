#ifndef _BIAS_H
#define _BIAS_H

#include <adf.h>
using namespace adf;

template<size_t H_SUPERTILE, size_t W_SUPERTILE>
class BiasAdd {
private:
	float (&weights)[W_SUPERTILE];

public:
	BiasAdd(float (&bias_w)[W_SUPERTILE]);

	void bias_add(input_window<float>* in, output_window<float>* out);

	static void registerKernelClass() {
		REGISTER_FUNCTION(BiasAdd::bias_add);
		REGISTER_PARAMETER(weights);
	}
};

#endif
