# Vector Norm

The Vector Norm example uses the *DMA-Streaming* and *AI-Engine* features for Versal devices. Input data is streamed from the DMA engine into our PE implemented in the programmable logic (PL). The PE splits the incoming stream into two outgoing streams and forwards the data to the AI Engines (AIEs).
The AIE graph then computes the vector norm $z = \sqrt{x^2 + y^2}$. The results are streamed back through the PL kernel and the DMA engine directly to host memory.

# Build Hardware

Use the `build_bitstream.sh` script to build the PE, AIE graph and generate the final device image. The following pre-requisites must be fulfilled:

- The PE is written in Bluspec SystemVerilog (BSV), make sure the [BSV compiler](https://github.com/B-Lang-org/bsc) `bsc` is installed.
- Make sure `vivado` is on your PATH (use at least Vivado 2023.1)
- Export the environment variable `VITIS_BASE` pointing to the installation directory of your Vitis installation
- Export `PLATFORM_FILE` pointing to the *.xpfm file for the VCK5000 (platform file is not included in TaPaSCo)
- Install all dependencies of the TaPaSCo toolflow as described [here](https://github.com/esa-tu-darmstadt/tapasco?tab=readme-ov-file#prerequisites-for-toolflow)
- *Optional:* Let `BSV_TOOLS` point to your [BSVTools](https://github.com/esa-tu-darmstadt/BSVTools) installation and use `source tapasco-setup.sh` in your custom TaPaSCo workspace. Otherwise the build script will clone and install BSVTools and TaPaSCo automatically.

You will find the generated PDI-file in `$TAPASCO_WORK_DIR/compose/axi4mm/vck5000/DataStreamerVN/001/312.5+AI-Engine+DMA-Streaming/axi4mm-vck5000--DataStreamerVN_1--313.pdi`.

### JSON Job Files

The build script uses a `.json` jobs file to generate the bitstream. In the following, we provide some details on the structure of this file as reference for your own job file.

First, we specify some general options for the desired design:

```jsonc
"Job": "Compose",              // type of job
"Design Frequency": 312.5,     // clock frequency for PEs
"SkipSynthesis": false,        // if 'true' only block design is generated (no synthesis)
"DeleteProjects": false,       // delete Vivado project after bitstream generation
"Platforms": [ "vck5000" ],    // list of platforms to build the bitstream for
"Architectures": [ "axi4mm" ], // only 'axi4mm' supported currently
```

Next, we specify which PEs and how many of them should be included in the design. In this example we only have one PE of type `DataStreamerVN`:

```jsonc
"Composition": {
  "Composition": [ {
      "Kernel": "DataStreamerVN",
      "Count": 1
  } ]
},
```

Finally, we configure the TaPaSCo features. Here, we use the `DMA-Streaming` and `AI-Engine` features.
For the `DMA-Streaming` feature we need to specify the interface ports used for the host-to-device and device-to-host streams. Note that only one stream in each direction is currently suppoerted by TaPaSCo.
The `AI-Engine` feature requires the path to the `libadf.a` graph, and you may also specify connections between the PLIOs of your AIE graph and PE interfaces.


```jsonc
"Features": [  {
    "Feature": "DMA-Streaming",      // feature name
    "Properties": {
      "master_port": "M_AXIS_DMA",   // name of PE interface for dev-to-host stream
      "slave_port": "S_AXIS_DMA"     // name of PE interface for host-to-dev stream
    }
  },
  {
    "Feature": "AI-Engine",
    "Properties": {
      "adf": "/path/to/libadf.a",    // path to libadf.a-file
      "in_x": "M_AXIS_AIE_X",        // connection between AIE graph PLIO and PE interface
      "in_y": "M_AXIS_AIE_Y",
      "out_z": "S_AXIS_AIE"
    }
} ]
```

# Build Software

Install required pre-requisites and build the TaPaSCo runtime as described [here](https://github.com/esa-tu-darmstadt/tapasco?tab=readme-ov-file#prerequisites-for-compiling-the-runtime). As *Rust* packages provided in package repositories are not always up-to-date, we suggest to install Rust manually using:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh && sh /tmp/rustup.sh -y
source ~/.cargo/env
```

Build the TaPaSCo runtime using:

```bash
source /path/to/tapasco/workspace/tapasco-setup.sh
tapasco-build-libs
```

Then build the software with `mkdir build && cd  build && cmake .. && make` in the software application directory (`sw/C++`). Note that the software requires *Boost (program options)* to be installed as well.

You can now run the application using `./vector-norm [--samples <number_of_samples>]`. Make sure to load the bitstream with `tapasco-load-bitstream` before. The example application expects that only one FPGA is connected to your host.

### Software Reference

In the following we describe some important TaPaSCo-specific parts of the host software. For more details on the C++ API have a look into the `tapasco.hpp`.

The first step is always to initialize your TaPaSCo device:

```c++
tapasco::Tapasco tap;
```

If you do not have the ID of your PE type at hand, you can easily retrieve it using the VLNV name of your IP core:

```c++
tapasco::PEId peId = tap.get_pe_id(PE_NAME);
```

Next, prepare the arguments and data transfers for your PE:

```c++
auto inputStream = tapasco::makeInputStream(input.data(), input.size() * sizeof(float));
auto outputStream = tapasco::makeOutputStream(output.data(), output.size() * sizeof(float));
unsigned int cycles = 0;
tapasco::RetVal<unsigned int> ret(&cycles);
```

If you want to use non-streaming data transfers, use `tapasco::makeWrappedPointer(*data, size)`. This will also allocate the required memory space in off-chip memory. Simple integer arguments do not require a wrapper.

Now we are ready to launch the task on our PE and wait for completion:

```c++
auto task = tap.launch(
        peId,           // ID of PE type
        ret,            // PE return value (register 0x10, optional)
        inputStream,    // stream arguments
        outputStream,
        num_samples);   // further arguments

// wait for PE completion
task();
```

TaPaSCo will handle all data transfers prior to and after the PE execution automatically as specified with the arguments to the `launch()`-call. The PE return value is optional.
All PE arguments must be in the correct order as they are supposed to be written into the argument registers of your PE (registers 0x20, 0x30, ...). For arguments of type `WrappedPointer`, the base address of the associated buffer in off-chip memory is written into the corresponding PE argument register.
Only `InputStream` and `OutputStream` do *not* have an associated argument register in your PE and can be placed anywhere after the return value in the `launch()` call.

