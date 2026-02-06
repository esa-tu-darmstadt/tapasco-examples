#!/bin/bash

# Check if exactly two arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <memory_type> <platform>"
    exit 1
fi

# Validate first argument
mem_type=$1
if [[ ! "$mem_type" =~ ^(uram|host-dram|on-board-dram)$ ]]; then
    echo "Error: Memory type must be one of 'uram', 'host-dram', or 'on-board-dram'."
    exit 1
fi

# Validate second argument
platform=$2
if [[ ! "$platform" =~ ^(AU280|xupvvh)$ ]]; then
    echo "Error: Platform must be either 'AU280' or 'xupvvh'."
    exit 1
fi

# check for vivado
if ! command -v vivado &> /dev/null; then
	echo "Command 'vivado' is missing, please add it to your PATH"
	exit 1
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
tapasco_dir="$(pwd)/build/tapasco"
if [ -z "$(ls build/tapasco)" ]; then
	git clone https://github.com/esa-tu-darmstadt/tapasco.git build/tapasco
fi

# create workspace
work_dir="$(pwd)/build/workspace-${mem_type}"
if [ -z "$(ls ${mem_type})" ]; then
	mkdir -p ${work_dir}
fi
pushd . && cd ${work_dir} && ${tapasco_dir}/tapasco-init.sh && source tapasco-setup.sh && popd
tapasco-build-toolflow

# build Bluespec cores
echo "Building Bluespec cores..."
pushd . && cd hw/NVMeReaderWriter/ && make SIM_TYPE=VERILOG ip && popd

# write job file
job_file_path=build/nvme-${platform}-${mem_type}-job.json
cat << EOF > "${job_file_path}"
[{
  "Job": "Compose",
  "Design Frequency": 300,
  "SkipSynthesis": false,
  "DeleteProjects": false,
  "Platforms": [
    "${platform}"
  ],
  "Architectures": [
    "axi4mm"
  ],
  "Composition": {
    "Composition": [
      {
        "Kernel": "NVMeReaderWriter",
        "Count": 1
      }
    ]
  },
  "Features": [
    {
      "Feature": "NVME",
      "Properties": {
        "enabled": "true",
        "axis_read_command": "M_NVME_READ_REQ",
        "axis_write_command": "M_NVME_WRITE_REQ",
        "axis_read_response": "S_NVME_READ_RSP",
        "axis_write_response": "S_NVME_WRITE_RSP",
        "memory": "${mem_type}"
      }
    },
    {
      "Feature": "CustomConstraints",
      "Properties": {
        "path": "$(pwd)/constraints/pblock-mem-${platform}.xdc"
      }
    }
  ]
}]
EOF

# build TaPaSCo bitstream
echo "Generating device image"
tapasco import hw/NVMeReaderWriter/build/ip/NVMeReaderWriter.zip as 4875 -p ${platform}
tapasco --jobsFile ${job_file_path}

bitstream_file_path=$TAPASCO_WORK_DIR/compose/axi4mm/${platform}/NVMeReaderWriter/001/300.0+CustomConstraints+NVME/axi4mm-${platform}--NVMeReaderWriter_1--300.bit
if [ -f "${bitstream_file_path}" ]; then
	echo "Device image created successfully"
	echo "Bitstream file: ${bitstream_file_path}"
else
	echo "ERROR: Failed to create device image"
fi
