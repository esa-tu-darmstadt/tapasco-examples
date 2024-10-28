# Vector Norm

The Vector Norm example uses the *DMA-Streaming* and *AI-Engine* features for Versal devices. Input data is streamed from the DMA engine into our PE implemented in the programmable logic (PL). The PE splits the incoming stream into two outgoing streams and forwards the data to the AI Engines (AIEs).
The AIE graph then computes the vector norm $z = \sqrt{x^2 + y^2}$. The results are streamed back through the PL kernel and the DMA engine directly to host memory.

# Build Hardware

Use the `build_bitstream.sh` script to build the PE, AIE graph and generate the final device image. The following pre-requisites must be fulfilled:

- The PE is written in Bluspec SystemVerilog (BSV), make sure the [BSV compiler](https://github.com/B-Lang-org/bsc) `bsv` is installed.
- Make sure `vivado` is on your PATH (use at least Vivado 2023.1)
- Export the environment variable `VITIS_BASE` pointing to the installation directory of your Vitis installation
- Export `PLATFORM_FILE` pointing to the *.xpfm file for the VCK5000 (platform file is not included in TaPaSCo)
- *Optional:* Let `BSV_TOOLS` point to your [BSVTools](https://github.com/esa-tu-darmstadt/BSVTools) installation and use `source tapasco-setup.sh` in your custom TaPaSCo workspace. Otherwise the build script will clone and install BSVTools and TaPaSCo automatically.

You will find the generated PDI-file in `$TAPASCO_WORK_DIR/compose/axi4mm/vck5000/DataStreamerVN/001/312.5+AI-Engine+DMA-Streaming/axi4mm-vck5000--DataStreamerVN_1--313.pdi`.

# Build Software

Run `source tapasco-setup.sh` in your TaPaSCo workspace and build the runtime using `tapasco-build-libs`. Make sure *CMake* and *Boost (program options)* are installed. Then build the software with `mkdir build && cd  build && cmake .. && make` in the software application directory (`sw/C++`).

You can then run the application using `./vector-norm [--samples <number_of_samples>]`. Make sure to load the bitstream with `tapasco-load-bitstream` before. The example application expects that only one FPGA is connected to your host.


