#include <iostream>

#include <boost/program_options.hpp>
#include <chrono>
#include <tapasco.hpp>

#define DEFAULT_SAMPLES 16384
#define PE_NAME "esa.informatik.tu-darmstadt.de:user:DataStreamerVN:1.0"

int main(int argc, char **argv) {

        boost::program_options::options_description desc;
        desc.add_options()
                ("samples", boost::program_options::value<std::size_t>()->default_value(DEFAULT_SAMPLES), "number of total samples");

        boost::program_options::variables_map vm;
        boost::program_options::store(boost::program_options::parse_command_line(argc, argv, desc), vm);
        boost::program_options::notify(vm);

        size_t num_samples = vm["samples"].as<std::size_t>();

        if (num_samples % 1024) {
                std::cout << "ERROR: number of samples must be multiple of 1024" << std::endl;
                return -1;
        } else if (num_samples > (1UL << 32)) {
                std::cout << "WARNING: truncating to maximum number of samples (" << (1UL << 32) << ")" <<  std::endl;
                num_samples = 1UL << 32;
        }

        std::vector<float> input;
        std::vector<float> output;
        input.resize(num_samples * 2);
        output.resize(num_samples);

        // populate input array
        std::cout <<  "Populate input array" << std::endl;
        for (size_t i = 0; i < num_samples; ++i) {
                input[i * 2] = (float)i;
                input[i * 2 + 1] = (float)(num_samples - i);
        }

        // instantiate Tapasco (assume only one FPGA connected to this host)
        tapasco::Tapasco tap;
        tapasco::PEId peId = tap.get_pe_id(PE_NAME);

        // define streams
        auto inputStream = tapasco::makeInputStream(input.data(), input.size() * sizeof(float));
        auto outputStream = tapasco::makeOutputStream(output.data(), output.size() * sizeof(float));
        unsigned int cycles = 0;
        tapasco::RetVal<unsigned int> ret(&cycles);

        // launch PE task
        std::cout <<  "Launch PE task" << std::endl;
        auto start = std::chrono::high_resolution_clock::now();
        auto task = tap.launch(peId, ret, inputStream, outputStream, num_samples);

        // wait for PE completion
        task();
        auto end = std::chrono::high_resolution_clock::now();

        // check results
        std::cout <<  "Check results" << std::endl;
        bool error = false;
        for (size_t i = 0; i < num_samples; ++i) {
                float x = input[i * 2];
                float y = input[i * 2 + 1];
                float ref = std::sqrt(x * x + y * y);

                float diff = ref - output[i];
                if (diff > ref * 1e-5) {
                        std::cout << "ERROR: Wrong result at index " << i << ": ";
                        std::cout << output[i] << "(act) vs. " << ref << " (ref)" << std::endl;
                        error = true;
                }
        }

        if (error)
                std::cout << "ERROR: Result contains false values, test run failed" << std::endl;
        else
                std::cout << "SUCCESS: Test run completed without errors" << std::endl;

        // print runtimes
        std::chrono::duration<double> dur = end - start;
        std::cout << "Host runtime: " << dur.count() << " s" << std::endl;
        double accRuntime = cycles / (tap.design_frequency() * 1e6);
        std::cout << "Accelerator runtime: " << accRuntime << " s" << std::endl;

        return 0;
}
