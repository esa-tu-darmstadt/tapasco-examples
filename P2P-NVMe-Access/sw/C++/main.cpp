/**
 * Copyright (c) 2025-2026 Embedded Systems and Applications Group, TU Darmstadt
 */
#include <iostream>
#include <boost/program_options.hpp>

#include <fcntl.h>
#include <sys/ioctl.h>

#include <tapasco.hpp>
#include <tapasco-nvme.hpp>
#include <nvme-device-ioctl.h>

#define PE_NAME "esa.informatik.tu-darmstadt.de:user:NVMeReaderWriter:1.0"

namespace po = boost::program_options;

/**
 * Command struct for IP
 */
struct Command {
    uint64_t rw;
    uint64_t nr_pages;
    uint64_t nvme_addr;
    uint64_t fpga_addr;
};

enum Direction {
    READ = 0,
    WRITE = 1
};

#define NUM_BUFS 7
std::array<uint64_t, NUM_BUFS> test_nvme_addrs = {
    0x00'0AC1'0000,
    0x01'0B10'0000,
    0x01'FAC0'0000,
    0x01'E00B'0000,
    0x00'1F20'0000,
    0x01'6000'0000,
    0x00'290A'C000
};
std::array<uint64_t, NUM_BUFS> test_len_in_pages = {
    38144,
    12310,
    512,
    423,
    189,
    28,
    37
};

/**
 * Generate input buffer
 *
 * @param id buffer ID
 * @param nr_pages length of buffer in number of 4K pages
 * @return vector of given length initialized with ID and incrementing values
 */
void populate_input(std::shared_ptr<std::vector<uint64_t>> &input, const uint64_t id) {
    for (uint64_t i = 0; i < input->size(); i++) {
        uint64_t val = id << 60 | i;
        input->at(i) = val;
    }
}

/**
 * Generate multiple vectors containing input data
 *
 * @tparam N number of vectors to create
 * @param lens lengths of input vectors
 * @return vector of pointers to vectors containing input data
 */
template<size_t N>
std::array<std::shared_ptr<std::vector<uint64_t>>, N> generate_all_inputs(std::array<uint64_t, N> &lens) {
    std::array<std::shared_ptr<std::vector<uint64_t>>, N> inputs;
    for (uint64_t i = 0; i < N; i++) {
        size_t vector_length = lens[i] * 4096 / sizeof(uint64_t);
        inputs[i] = std::make_shared<std::vector<uint64_t>>(vector_length);
        populate_input(inputs[i] , i);
    }
    return inputs;
}

/**
 * Allocate empty vectors for output data
 *
 * @tparam N number of vectors to allocate
 * @param lens lengths of output vectors
 * @return vector of pointers to empty vectors for output data
 */
template<size_t N>
std::array<std::shared_ptr<std::vector<uint64_t>>, N> allocate_outputs(std::array<uint64_t, N> &lens) {
    std::array<std::shared_ptr<std::vector<uint64_t>>, N> outputs;
    for (uint64_t i = 0; i < N; i++) {
        size_t vector_length = lens[i] * 4096 / sizeof(uint64_t);
        outputs[i] = std::make_shared<std::vector<uint64_t>>(vector_length);
    }
    return outputs;
}

/**
 * Check whether values in given output vector match the corresponding input
 *
 * @param id buffer ID
 * @param output vector with data to be checked
 * @return number of wrong values in vector
 */
size_t check_output(const uint64_t id, const std::shared_ptr<std::vector<uint64_t>> &output) {
    size_t errors = 0;
    for (uint64_t i = 0; i < output->size(); i++) {
        uint64_t ref = id << 60 | i;
        if (output->at(i) != ref) {
            ++errors;
        }
    }
    return errors;
}

/**
 * Check whether the output vectors contain the expected data (equal to input data)
 *
 * @tparam N number of vectors to check
 * @param outputs output vectors to check
 * @return number of wrong values in output vectors
 */
template<size_t N>
size_t check_all_outputs(std::array<std::shared_ptr<std::vector<uint64_t>>, N> &outputs) {
    size_t total_errors = 0;
    for (size_t i = 0; i < N; i++) {
        auto errors = check_output(i, outputs[i]);
        if (errors) {
            std::cout << "ERROR: " << errors << " wrong values in output #" << i << std::endl;
            total_errors += errors;
        } else {
            std::cout << "OK: No wrong values in output #" << i << std::endl;
        }
    }
    return total_errors;
}

/**
 * Allocate buffers in on-board DRAM of FPGA board
 *
 * @tparam N number of buffers to allocate
 * @param tapasco pointer to TaPaSCo device
 * @param lens lengths of buffers to allocate
 * @return array of device addresses of allocated buffers
 */
template<size_t N>
std::array<tapasco::DeviceAddress, N> allocate_device_memory(std::shared_ptr<tapasco::Tapasco> &tapasco, std::array<uint64_t, N> &lens) {
    std::array<tapasco::DeviceAddress, N> dev_addrs{};
    for (size_t i = 0; i < N; i++) {
        tapasco::DeviceAddress a;
        tapasco->alloc(a, lens[i] * 4096);
        dev_addrs[i] = a;
    }
    return dev_addrs;
}

/**
 * Free buffers in on-board DRAM of FPGA board
 *
 * @tparam N number of buffers to free
 * @param tapasco pointer to TaPaSCo device
 * @param dev_addrs addresses of buffers to free
 */
template<size_t N>
void free_device_memory(std::shared_ptr<tapasco::Tapasco> &tapasco, std::array<tapasco::DeviceAddress, N> &dev_addrs) {
    for (auto &a : dev_addrs) {
        tapasco->free(a);
    }
}

/**
 * Copy input data from vectors to buffers in on-board DRAM on FPGA board
 *
 * @tparam N number of buffers to copy
 * @param tapasco pointer to TaPaSCo device
 * @param inputs vectors containing data to copy
 * @param dev_addrs destination addresses in on-board DRAM
 */
template<size_t N>
void copy_input_data(std::shared_ptr<tapasco::Tapasco> &tapasco, std::array<std::shared_ptr<std::vector<uint64_t>>, N> &inputs,
        std::array<tapasco::DeviceAddress, N> &dev_addrs) {
    for (size_t i = 0; i < N; i++) {
        tapasco->copy_to((uint8_t *)inputs[i]->data(), dev_addrs[i], inputs[i]->size() * sizeof(uint64_t));
    }
}

/**
 * Copy output data from buffers in on-board DRAM of FPGA board to given vectors
 *
 * @tparam N number of buffers to copy
 * @param tapasco pointer to TaPaSCo device
 * @param outputs vectors data should be copied to
 * @param dev_addrs buffer addresses containing data in on-board DRAM
 */
template<size_t N>
void copy_output_data(std::shared_ptr<tapasco::Tapasco> &tapasco, std::array<std::shared_ptr<std::vector<uint64_t>>, N> &outputs,
        std::array<tapasco::DeviceAddress, N> &dev_addrs) {
    for (size_t i = 0; i < N; i++) {
        tapasco->copy_from(dev_addrs[i], (uint8_t *)outputs[i]->data(), outputs[i]->size() * sizeof(uint64_t));
    }
}

/**
 * Generate commands for NVMeReaderWriter IP
 *
 * @tparam N number of commands to be generated
 * @param fpga_addrs buffer addresses in on-board DRAM
 * @param nvme_addrs addresses on NVMe device
 * @param lens lengths of read/write commands
 * @param dirs direction of commands (read/write)
 * @return array of generated command structs
 */
template<size_t N>
std::array<Command, N> generate_commands(std::array<tapasco::DeviceAddress, N> &fpga_addrs, std::array<uint64_t, N> &nvme_addrs,
    std::array<uint64_t, N> &lens, std::array<Direction, N> &dirs)
{
    std::array<Command, N> cmds;
    for (size_t i = 0; i < N; i++) {
        cmds[i].fpga_addr = fpga_addrs[i];
        cmds[i].nvme_addr = nvme_addrs[i];
        cmds[i].nr_pages = lens[i];
        cmds[i].rw = dirs[i];
    }
    return cmds;
}

int main(int argc, char **argv) {
    // command line interface
    po::options_description desc;
    desc.add_options()
        ("help,h", "print this help message")
        ("reset-io-queue", "Reset IO queue for FPGA in NVMe controller before test execution")
        ("release-io-queue", "Release IO queue FPGA in NVMe controller after test execution");

    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, desc), vm);
    po::notify(vm);
    if (vm.count("help")) {
        std::cout << desc << std::endl;
        return 0;
    }

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

    // retrieve NVMe plugin
    auto nvme_plugin = tapasco->get_plugin<tapasco::TapascoNvmePlugin>();
    if (!nvme_plugin.is_available()) {
        std::cout << "ERROR: NVMe plugin not available" << std::endl;
        return 1;
    }

    // retrieve PCIe address of SQ and CQ on the FPGA
    auto [sq_addr, cq_addr] = nvme_plugin.get_queue_base_addr();

    // open NVMe driver file
    int nvme_fd = open("/dev/nvme-host-driver", O_RDWR);
    if (nvme_fd < 0) {
        std::cout << "ERROR: Unable to open NVMe host driver" << std::endl;
        return 1;
    }

    // retrieve PCIe base address of NVMe controller
    size_t nvme_pcie_addr = 0;
    if (ioctl(nvme_fd, NVME_GET_PCIE_BASE, &nvme_pcie_addr) || !nvme_pcie_addr) {
        std::cout << "ERROR: Unable to get PCIe base address of NVMe controller" << std::endl;
        close(nvme_fd);
        return 1;
    }

    // reset NVMe IO queue (only required if bitstream has been reloaded/reset)
    if (vm.count("reset-io-queue")) {
        struct ioctl_release_io_queue_cmd release_io_queue_cmd = {0};
        if (ioctl(nvme_fd, NVME_RELEASE_IO_QUEUE, &release_io_queue_cmd)
            || release_io_queue_cmd.status == RELEASE_IO_QUEUE_FAILED) {
            std::cout << "ERROR: Unable to release IO queue for FPGA" << std::endl;
            close(nvme_fd);
            return 1;
        }
        if (release_io_queue_cmd.status == RELEASE_IO_QUEUE_SUCCESS) {
            std::cout << "Release IO queue as part of reset" << std::endl;
        } else if (release_io_queue_cmd.status == RELEASE_IO_QUEUE_NOT_PRESENT) {
            std::cout << "Could not reset IO queue, was not set up before" << std::endl;
        }
    }

    // setup IO queue in NVMe controller
    struct ioctl_setup_io_queue_cmd setup_queue_cmd = {0};
    setup_queue_cmd.sq_addr = sq_addr;
    setup_queue_cmd.cq_addr = cq_addr;
    if (ioctl(nvme_fd, NVME_SETUP_IO_QUEUE, &setup_queue_cmd)) {
        std::cout << "ERROR: NVMe setup queue command failed" << std::endl;
        close(nvme_fd);
        return 1;
    }
    if (setup_queue_cmd.status == CREATE_IO_QUEUE_FAILED) {
        std::cout << "ERROR: IO queue creation failed" << std::endl;
        close(nvme_fd);
        return 1;
    }
    if (setup_queue_cmd.status == CREATE_IO_QUEUE_SUCCESS) {
        std::cout << "SUCCESS: IO queue successfully created" << std::endl;
    } else if (setup_queue_cmd.status == CREATE_IO_QUEUE_PRESENT) {
        std::cout << "WARN: IO queue already set up...do you want to continue (y/n)?" << std::endl;
        char c = getchar();
        if (c != 'y' && c != 'Y') {
            std::cout << "Aborting execution" << std::endl;
            close(nvme_fd);
            return 0;
        }
    } else {
        std::cout << "ERROR: Unknown return status of IOCTL call" << std::endl;
        close(nvme_fd);
        return 1;
    }

    // configure NVMe plugin
    nvme_plugin.set_nvme_pcie_addr(nvme_pcie_addr);
    nvme_plugin.enable();

    // generate input data
    auto input_data = generate_all_inputs(test_len_in_pages);

    // allocate empty output buffers
    auto output_data = allocate_outputs(test_len_in_pages);

    /*
     * -----------------
     * First iteration:
     * - Write four buffers to NVMe
     * -----------------
     */
    std::array inputs_1 = {input_data[1], input_data[2], input_data[3], input_data[5]};
    std::array nvme_addrs_1 = {test_nvme_addrs[1], test_nvme_addrs[2], test_nvme_addrs[3], test_nvme_addrs[5]};
    std::array lens_1 = {test_len_in_pages[1], test_len_in_pages[2], test_len_in_pages[3], test_len_in_pages[5]};
    std::array dirs_1 = {WRITE, WRITE, WRITE, WRITE};

    // allocate input buffer in device memory
    auto dev_addrs_1 = allocate_device_memory(tapasco, lens_1);

    // copy input data to device memory
    copy_input_data(tapasco, inputs_1, dev_addrs_1);

    // generate commands for first execution
    auto cmds_1 = generate_commands(dev_addrs_1, nvme_addrs_1, lens_1, dirs_1);
    auto cmds_1_in = tapasco::makeInOnly(tapasco::makeWrappedPointer((uint8_t *)cmds_1.data(), cmds_1.size() * sizeof(Command)));

    // launch first task
    std::cout << "Start first task on PE" << std::endl;
    auto task_1 = tapasco->launch(pe_id, cmds_1_in, cmds_1.size());
    task_1();
    std::cout << "First task on PE completed" << std::endl;

    // free buffers in device memory
    free_device_memory(tapasco, dev_addrs_1);

    /*
     * -----------------
     * Second iteration:
     * - Read back the four buffers from the first iteration
     * - Write three new buffers
     * -----------------
    */
    std::array inputs_2 = {input_data[0], input_data[4], input_data[6]};
    std::array outputs_2 = {output_data[1], output_data[2], output_data[3], output_data[5]};
    std::array dirs_2 = {WRITE, READ, READ, READ, WRITE, READ, WRITE};

    // allocate buffer in device memory (input and output)
    auto dev_addrs_2 = allocate_device_memory(tapasco, test_len_in_pages);
    std::array dev_addrs_in_2 = {dev_addrs_2[0], dev_addrs_2[4], dev_addrs_2[6]};
    std::array dev_addrs_out_2 = {dev_addrs_2[1], dev_addrs_2[2], dev_addrs_2[3], dev_addrs_2[5]};

    // copy input data to device memory
    copy_input_data(tapasco, inputs_2, dev_addrs_in_2);

    // generate commands for second execution
    auto cmds_2 = generate_commands(dev_addrs_2, test_nvme_addrs, test_len_in_pages, dirs_2);
    auto cmds_2_in = tapasco::makeInOnly(tapasco::makeWrappedPointer((uint8_t *)cmds_2.data(), cmds_2.size() * sizeof(Command)));

    // launch second task
    std::cout << "Start second task on PE" << std::endl;
    auto task_2 = tapasco->launch(pe_id, cmds_2_in, cmds_2.size());
    task_2();
    std::cout << "Second task on PE completed" << std::endl;

    // copy output data
    copy_output_data(tapasco, outputs_2, dev_addrs_out_2);

    // free buffers in device memory
    free_device_memory(tapasco, dev_addrs_2);

    /*
     * -----------------
     * Third iteration:
     * - Read back the three buffers from the second iteration
     * -----------------
    */
    std::array outputs_3 = {output_data[0], output_data[4], output_data[6]};
    std::array nvme_addrs_3 = {test_nvme_addrs[0], test_nvme_addrs[4], test_nvme_addrs[6]};
    std::array lens_3 = {test_len_in_pages[0], test_len_in_pages[4], test_len_in_pages[6]};
    std::array dirs_3 = {READ, READ, READ};

    // allocate buffer in device memory (input and output)
    auto dev_addrs_3 = allocate_device_memory(tapasco, lens_3);

    // generate commands for second execution
    auto cmds_3 = generate_commands(dev_addrs_3, nvme_addrs_3, lens_3, dirs_3);
    auto cmds_3_in = tapasco::makeInOnly(tapasco::makeWrappedPointer((uint8_t *)cmds_3.data(), cmds_3.size() * sizeof(Command)));

    // launch second task
    std::cout << "Start third task on PE" << std::endl;
    auto task_3 = tapasco->launch(pe_id, cmds_3_in, cmds_3.size());
    task_3();
    std::cout << "Third task on PE completed" << std::endl;

    // copy output data
    copy_output_data(tapasco, outputs_3, dev_addrs_3);

    // free buffers in device memory
    free_device_memory(tapasco, dev_addrs_3);

    // disable NVMe plugin
    nvme_plugin.disable();

    // check all outputs
    auto total_errors = check_all_outputs(output_data);
    if (total_errors)
        std::cout << "ERROR: Test failed with " << total_errors << " wrong output values" << std::endl;
    else
        std::cout << "SUCCESS: Test completed without errors" << std::endl;

    // destroy IO queue in NVMe driver (requires bitstream reload before next launch)
    if (vm.count("release-io-queue")) {
        struct ioctl_release_io_queue_cmd release_io_queue_cmd = {0};
        if (ioctl(nvme_fd, NVME_RELEASE_IO_QUEUE, &release_io_queue_cmd)
            || release_io_queue_cmd.status != RELEASE_IO_QUEUE_SUCCESS)
        {
            std::cout << "Failed to release IO queue" << std::endl;
            return 1;
        }
    }

    // close NVMe driver file
    close(nvme_fd);

    return 0;
}