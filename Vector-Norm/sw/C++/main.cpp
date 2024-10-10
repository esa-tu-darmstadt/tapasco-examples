#include <iostream>

#include <boost/program_options.hpp>
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
        }

        std::vector<float> input;
        std::vector<float> output;
        input.resize(num_samples * 2);
        output.resize(num_samples);

        // populate input array
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

        // launch PE task
        auto task = tap.launch(peId, inputStream, outputStream, num_samples);

        // wait for PE completion
        task();

        // check results
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

        return 0;
}
