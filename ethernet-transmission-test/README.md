# Ethernet Transmission Test

In this example, we connect two FPGAs using a 100G Ethernet connection.

## Build Hardware

Our PEs in this examples are both written in Bluespec SystemVerilog (BSV). Make sure you have the BSV compiler `bsc` installed.

Also, you require the `BSVTools` provided on our Github:

```bash
git clone https://github.com/esa-tu-darmstadt/BSVTools.git </path/to/BSVTools>
export BSV_TOOLS=</path/to/BSVTools>
```

Include Vivado on your path, and you are ready to build and package the two PEs by using:

```bash
cd hw/EthernetReceiver && make SIM_TYPE=VERILOG ip && cd ..
cd hw/EthernetTransmitter && make SIM_TYPE=VERILOG ip && cd ..
```

Download and build the TaPaSCo toolflow as described in our Github:

```bash
git clone https://github.com/esa-tu-darmstadt/tapasco.git </path/to/tapasco-git>
mkdir </path/to/workspace>
pushd . && cd </path/to/workspace> && </path/to/tapasco-git>/tapasco-init.sh && source tapasco-setup.sh && popd
tapasco-build-toolflow
```

Import both PEs and use one of the example JSON-scripts to build your bitstreams:

```bash
tapasco import EthernetReceiver/build/ip/EthernetReceiver.zip as 7445
tapasco import EthernetTransmitter/build/ip/EthernetTransmitter.zip as 7446
tapasco --jobsFile tapasco-jobs-files/network-jobs-vck.json
```

## Build Software

Edit the path of the `tapasco` dependencie in `sw/Rust/ethernet_transmit_test/Cargo.toml` to point to your cloned TaPaSCo git. Then you can build the software using:

```bash
cd sw/Rust/ethernet_transmit_test
cargo build
cargo run -- [[options]]
```

Check the availabe options with `cargo run -- -h`.
