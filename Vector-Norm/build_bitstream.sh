#!/bin/bash

# check environment variables
if [ -z "${VITIS_BASE}" ]; then
	echo "VITIS_BASE is not set. Please set it to your Vitis installation directory path."
	exit
fi

if [ -z "${PLATFORM_FILE}" ]; then
	echo "PLATFORM_FILE is not set. Please set it to the path to your xpfm-platform"
	exit
fi

# check for vivado
if ! command -v vivado &> /dev/null; then
	echo "Command 'vivado' is missing, please add it to your PATH"
	exit
fi

# clone BSV tools if necessary
mkdir -p build
if [ -z "${BSV_TOOLS}" ]; then
	if ! [ -d build/BSVTools ]; then
		git clone https://github.com/esa-tu-darmstadt/BSVTools.git build/BSVTools
	fi
	export BSV_TOOLS=$PWD/build/BSVTools
fi

# clone TaPaSCo if variables are not set
if [ -z "${TAPASCO_WORK_DIR}" ]; then
	if ! [ -d build/tapasco ]; then
		git clone https://github.com/esa-tu-darmstadt/tapasco.git build/tapasco
	fi
	if ! [ -d build/workspace ]; then
		mkdir -p build/workspace
		pushd . && cd build/workspace
		../tapasco/tapasco-init.sh
		popd
	fi
	source build/workspace/tapasco-setup.sh
	tapasco-build-toolflow
fi

# build Bluespec cores
echo "Building Bluespec cores..."
pushd . && cd hw/DataStreamerVN && make SIM_TYPE=VERILOG ip && popd

# build AIE graph
echo "Compiling AIE graph..."
pushd . && pwd && cd aie && make && popd

# build TaPaSCo bitstream
echo "Generating device image"
sed -i "s,PATH_TO_THIS_REPO,$PWD,g" vector-norm.json
tapasco import hw/DataStreamerVN/build/ip/DataStreamerVN.zip as 8847 -p vck5000
tapasco --jobsFile vector-norm.json

if [ -f $TAPASCO_WORK_DIR/compose/axi4mm/vck5000/DataStreamerVN/001/312.5+AI-Engine+DMA-Streaming/axi4mm-vck5000--DataStreamerVN_1--313.pdi ]; then
	echo "Device image created successfully"
	echo "PDI file: $TAPASCO_WORK_DIR/compose/axi4mm/vck5000/DataStreamer__WeightStreamer/001_001/312.5+AI-Engine+DMA-Streaming/axi4mm-vck5000--DataStreamer_1_WeightStreamer_1--313.pdi"
else
	echo "ERROR: Failed to create device image"
fi
