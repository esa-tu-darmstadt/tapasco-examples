#ifndef _JOINER_H
#define _JOINER_H

#include <adf.h>
#include <aie_api/aie.hpp>
#include <aie_api/aie_adf.hpp>
using namespace adf;
/**
 * This kernel expects two windows streaming 4x4 tiles and concatenates the
 * rows outputting 4x4 tiles.
 * Template parameters:
 * 		H = Number of rows in supertile (number of values in a column)
 * 		W = Number of columns in supertile (number of values in a row)
 * */
template<size_t H, size_t W>
void join_supertiles(adf::input_buffer<float, adf::extents<H*W>> & left_in, input_buffer<float, adf::extents<H*W>> & right_in, output_buffer<float, adf::extents<2*H*W>> & concat_out);

#endif
