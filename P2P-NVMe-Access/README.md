# Peer-to-Peer NVMe Access

This example uses the [NVMe extension](https://github.com/esa-tu-darmstadt/tapasco/blob/master/documentation/tapasco-nvme.md) of TaPaSCo for direct streaming-based read and write access to an NVMe device using peer-to-peer PCIe transfers.

## Example Components

In this section, we introduce the three components of this example: our hardware PE on the FPGA, the corresponding host software, and our simple NVMe driver for configuring the NVMe controller of the used SSD. 

### NVMeReaderWriter PE

The NVMeReaderWriter PE is written in Bluespec and the source code can be found in the [hw](hw) subfolder. The PE reads a given number of commands in a custom format from on-board DRAM. Each command describes a transfer from or to the NVMe device and consists of a buffer address in on-board DRAM, an address on the NVMe device as well as the transfer length and direction (read/write). The PE executes each command and writes data from the on-board DRAM buffer to the NVMe device, or the other way around, respectively. Communication with the NVMe device is done using the four AXI4 Streams connections provided by the NVMe feature of TaPaSCo described [here](https://github.com/esa-tu-darmstadt/tapasco/blob/master/documentation/tapasco-nvme.md#interfacing-with-user-pe).

### Host Software

The provided host software writes to and reads back from the NVMe device seven buffers in total. In the first iteration, it issues four write transfers to the hardware PE. The second iteration is a mix of read and write transfers by reading back the first four buffers and writing three new ones, before reading these back in the last iteration. Last, the software checks input and output data are identical.

In the following, we briefly describe the most important code snippets regarding the usage of TaPaSCo and our NVMe driver in the main function in [sw/C++/main.cpp](sw/C++/main.cpp). For more details, have a look at [tapasco.hpp](https://github.com/esa-tu-darmstadt/tapasco/blob/master/runtime/libtapasco/src/tapasco.hpp) and [tapasco-nvme.hpp](https://github.com/esa-tu-darmstadt/tapasco/blob/master/runtime/libtapasco/src/plugins/tapasco-nvme.hpp) themselves. First, we assume that multiple FPGAs are connected to our host, so we iterate over all available devices, until we find one which has loaded a bitstream containing our PE:

```c++
    // search for matching TaPaSCo device with NVMeReaderWriter PE
    std::cout << "Search for TaPaSCo device with NVMeReaderWriter PE" << std::endl;
    tapasco::TapascoDriver tlkm;
    std::shared_ptr<tapasco::Tapasco> tapasco;
    tapasco::PEId pe_id = 0;
    // open each device
    for (int d = 0; d < tlkm.num_devices(); d++) {
        auto *t = new tapasco::Tapasco(tapasco::tlkm_access::TlkmAccessExclusive, d);
        if (t) {
            try {
                // throws exception if PE name is unknown
                pe_id = t->get_pe_id(PE_NAME);

                // no exception -> found FPGA containing our PE
                tapasco.reset(t);
                break;
            } catch (tapasco::tapasco_error &err) {}
            delete t;
        }
    }
    if (!tapasco) {
        std::cout << "ERROR: No device found" << std::endl;
        return 1;
    }
    std::cout << "Found PE on TaPaSCo device" << std::endl;
```

With the NVMe feature, we also introduced a new runtime plugin system to TaPaSCo. This plugin adds specific functionality which is not covered by the general API. So the next step is to retrieve the plugin and check whether the NVMe extension is available in the loaded bitstream:

```c++
    // retrieve NVMe plugin
    auto nvme_plugin = tapasco->get_plugin<tapasco::TapascoNvmePlugin>();
    if (!nvme_plugin.is_available()) {
        std::cout << "ERROR: NVMe plugin not available" << std::endl;
        return 1;
    }
```

Then, we can query the plugin for the PCIe base addresses of the NVMe submission and completion queues managed on the FPGA:

```c++
    auto [sq_addr, cq_addr] = nvme_plugin.get_queue_base_addr();
```

After opening the driver device file with ```int fd = open("/dev/nvme-host-driver", O_RDWR)```, we can use `sq_addr` and `cq_addr` to create the corresponding IO queue pair in the NVMe controller by calling the respective IOCTL of our driver:

```c++
    // setup IO queue in NVMe controller
    struct ioctl_setup_io_queue_cmd setup_queue_cmd = {0};
    setup_queue_cmd.sq_addr = sq_addr;
    setup_queue_cmd.cq_addr = cq_addr;
    if (ioctl(nvme_fd, NVME_SETUP_IO_QUEUE, &setup_queue_cmd)) {
        std::cout << "ERROR: NVMe setup queue command failed" << std::endl;
        close(nvme_fd);
        return 1;
    }
```

Now the NVMe controller knows where to find the submission and completion queue on the PCIe bus, but we also have to tell the TaPaSCo infrastructure IP where the NVMe controller is located. So we retrieve the NVMe controller's PCIe address from the driver:

```c++
    // retrieve PCIe base address of NVMe controller
    size_t nvme_pcie_addr = 0;
    if (ioctl(nvme_fd, NVME_GET_PCIE_BASE, &nvme_pcie_addr) || !nvme_pcie_addr) {
        std::cout << "ERROR: Unable to get PCIe base address of NVMe controller" << std::endl;
        close(nvme_fd);
        return 1;
    }
```

We then pass the queues' addresses to the TaPaSCo NVMe plugin and enable it:

```c++
    nvme_plugin.set_nvme_pcie_addr(nvme_pcie_addr);
    nvme_plugin.enable();
```

In this example, we use both manual and automatic memory management of the on-board DRAM. On the one hand, the buffers containing the data to be transferred to and from the NVMe device are allocated manually in `allocate_device_memory()`:

```c++
    tapasco::DeviceAddress a;
    tapasco->alloc(a, lens[i] * 4096);
```

Also, copying of the data is done manually in `copy_input_data()` and `copy_output_data()` using `tapasco->copy_to()` and `tapasco->copy_from()`. Do not forget to free manually allocated device memory using `tapasco->free()`.

On the other hand, we use automatic memory management for the buffer containing our NVMe commands by passing it as argument to the `tapasco->launch()` call:

```c++
    // generate commands for first execution
    auto cmds_1 = generate_commands(dev_addrs_1, nvme_addrs_1, lens_1, dirs_1);
    auto cmds_1_in = tapasco::makeInOnly(tapasco::makeWrappedPointer((uint8_t *)cmds_1.data(), cmds_1.size() * sizeof(Command)));

    // launch first task
    std::cout << "Start first task on PE" << std::endl;
    auto task_1 = tapasco->launch(pe_id, cmds_1_in, cmds_1.size());
    task_1();
    std::cout << "First task on PE completed" << std::endl;
```

`cmds_i` is an array of `Command`. By wrapping the `cmds_i.data()` pointer using `tapasco::makeWrappedPointer`, we mark this buffer for a data transfer. In addition, we use `tapasco::makeInOnly()` to tell the runtime that this data buffer must only be copied to device memory prior to launching the PE, but not copied back to host memory after the PE has completed. There is also the opposite `tapasco::makeOutOnly()` option available. During `tapasco->launch()`, the runtime allocates device memory, copies the data to device memory and passes the buffer's base address to the respective argument register of the PE. Then execution of the PE is started.

Arguments which are not of the type `WrappedPointer` are passed directly to the respective argument register, as `cmds_i.size()` in this example. Arguemnts are strictly processed and written to argument registers in the order they are passed to `tapasco->launch()`. We do not use the optional return value, which would be passed between `pe_id` and the first PE argument, here.

`tapasco->launch()` returns a `JobFuture` object. By calling this object, execution of the current thread is blocked until the PE has sent an interrupt. After that, the runtime now performs all data transfers back to host memory if not marked with `tapasco::makeInOnly`.

The example software also has the option to reset and release the IO queue pair in the NVMe controller. The reset is only required if the NVMe controller and the TaPaSCo NVMe infrastructure PE are out of sync. This happens if the bitstream is reloaded but not the NVMe driver. After releasing the queue pair in the NVMe controller, the FPGA bitstream must be reloaded as well to have a clean state for the next execution.

### NVMe Host Driver

In addition to the FPGA, the NVMe device has to be configured as well. While using the Linux NVMe driver or a user-space-based approach could be possible, we decided to provide our own simple NVMe driver for this example in [nvme-host-driver](nvme-host-driver). When the driver is loaded, it resets the NVMe controller, creates the admin queue pair and one IO queue pair. The IO queue pair can be used to access the NVMe device from software.

On request, the driver creates a second IO queue pair to be used for direct access to the NVMe device from the FPGA. In this case, the actual ring buffer for the submission and completion queue is located on the FPGA. The driver initially configures the NVMe controller but is not involved in any further communication between the TaPaSCo infrastructure IP and the NVMe controller.

In addition, the host software can query the NVMe controller's PCIe address in order to forward it to TaPaSCo. All functionality of the driver is exposed using IOCTL commands.

## Build Hardware

Make sure the following prerequisites are fulfilled to build the bitstreams of this example:

- The PE is written in Bluspec SystemVerilog (BSV), make sure the [BSV compiler](https://github.com/B-Lang-org/bsc) `bsc` is installed.
- Make sure `vivado` is on the PATH
- Install all dependencies of the TaPaSCo toolflow as described [here](https://github.com/esa-tu-darmstadt/tapasco?tab=readme-ov-file#prerequisites-for-toolflow)

Then use our build script to generate the desired bitstream:

```bash
bash build_bitstream <memory_type> <platform>
```

`<memory_type>` must be one of `uram`, `host-dram` and `on-board-dram`. See [here](https://github.com/esa-tu-darmstadt/tapasco/blob/master/documentation/tapasco-nvme.md#nvme-streamer-ip-and-memory-choice-for-data-transfers) for a detailed description on the choice of memory for data transfers between FPGA and NVMe device. Consider that on-board DRAM is also used to hold the data which is transferred to the NVMe device limiting the available bandwidth. Supported platforms are currently `AU280` and `xupvvh`.

The bash script compiles the Bluespec PE, clones and builds TaPaSCo, creates a workspace, and finally generates the bitstream with the help of a job file. The job file will be written to the `build` directory and can be used as basis for your own projects. Also, the job file shows how to include custom constraint files. In this example, we constrain components of the memory subsystem to a specific SLR to achieve timing closure, since we have seen during testing that Vivado often chooses a suboptimal placement.

Load the generated bitstream file on FPGA using

```bash
tapasco-load-bitstream <bitstream_file> --verbose [--reload-driver] [--adapter <adapter_id>]
```

The `--adapter` option is required if you have more than one FPGA and programming adapter attached to this machine. Use

```bash
tapasco-load-bitstream <bitstream_file> --verbose --list-adapter
```

to list all adapters connected to this machine to find the correct one.

## Build and Run Software

Install required prerequisites and build the TaPaSCo runtime as described [here](https://github.com/esa-tu-darmstadt/tapasco?tab=readme-ov-file#prerequisites-for-compiling-the-runtime). Then build the host software using CMake:

```bash
mkdir -p sw/C++/build && cd sw/C++/build && cmake .. && make
```

Before running the host software, you also have to compile and load the NVMe driver. First, identify the NVMe device you want to use for this test using `lsblk` and `lspcie`. Make sure that it is not holding any data or your operating system, as we will write random raw data to the device. Unload the Linux driver for the device if necessary:

```bash
sudo sh -c "echo <pcie_id> > /sys/bus/pci/devices/<pcie_id>/driver/unbind"
```

Now you can compile and load the provided driver:

```bash
cd nvme-host-driver && make && sudo make load
```

Finally, run the host software:

```bash
export RUST_LOG=info # optionally for additional output 
cd sw/C++/build && ./nvme-rw-sw [--help] [--reset-io-queue] [--release-io-queue]
```
