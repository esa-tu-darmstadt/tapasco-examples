
AIE_FLAGS :=-v -Xchess=main:darts.xargs=-nb -target=hw -workdir=./work
AIE_FLAGS +=-platform=$(PLATFORM_FILE)
AIE_FLAGS +=-include=$(VITIS_BASE)/aietools/include
AIE_FLAGS +=-include=$(VITIS_LIBRARIES)/dsp/L1/include/aie
AIE_FLAGS +=-include=$(VITIS_LIBRARIES)/dsp/L1/src/aie
AIE_FLAGS +=-include=$(VITIS_LIBRARIES)/dsp/L1/tests/aie/inc
AIE_FLAGS +=-include=$(VITIS_LIBRARIES)/dsp/L1/tests/aie/src
AIE_FLAGS +=-include=$(VITIS_LIBRARIES)/dsp/L2/include/aie
AIE_FLAGS +=-include=$(VITIS_LIBRARIES)/dsp/L2/tests/aie/common/inc
AIE_FLAGS +=-include=src
AIE_CC :=$(VITIS_BASE)/aietools/bin/aiecompiler

all: libadf.a

libadf.a: src/graph.cpp
	mkdir -p work
	$(AIE_CC) $(AIE_FLAGS) $^

