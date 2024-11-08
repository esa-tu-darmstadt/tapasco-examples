# Feed Forward NN

This example implements a simple feed forward neural network on the AI Engines of the VCK5000. It also uses the DMA streaming feature of TaPaSCo to move data from and to the device. The FPGA kernels are implemented in Bluespec SystemVerilog

## Build HW

Use the ```build_bitstream.sh``` script to build the Bluespec cores, AI Engine graph and generate the final device image. Provide at least ```VITIS_BASE``` pointing to your Vitis installation, and ```PLATFORM_FILE``` pointing to your xpfm-file for the VCK5000. Use Vitis 2023.2 and the corresponding Vitis_Libraries version.

## Build SW

Go to ```sw/Rust/feed_forward_nn``` and substitute the path of your TaPaSCo repository in the ```Cargo.toml```. Then build the software with ```cargo run [-- -n <num-samples> | -b | -i <iterations>]```.
