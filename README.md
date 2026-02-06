# TaPaSCo Examples

Welcome to our TaPaSCo examples repository. This repository provides full-stack examples of the [TaPaSCo Open-Source Toolflow](https://github.com/esa-tu-darmstadt/tapasco), covering the complete workflow — from writing and building a custom accelerator (PE), through hardware design and bitstream generation, to developing the corresponding host software and deploying the project on the target hardware.

## Included Projects

| Subfolder                                                | Covered Features          | API  | Description |
|----------------------------------------------------------|---------------------------|------|-------------|
| [ethernet-transmission-test](ethernet-transmission-test) | SFPPPLUS (100G Ethernet)  | Rust | Transmit data from one to another FPGA using an external 100G Ethernet link. Both FPGAs are connected to the same host. |
| [P2P-NVMe-Access](P2P-NVMe-Access)                       | NVMe, Custom XDC          | C++  | Use TaPaSCo NVMe feature to read and write data from and to an SSD directly from the FPGA. Uses custom XDC to constraints some IPs to an SLR. |
| [Vector-Norm](Vector-Norm)                               | DMA-Streaming, AI Engines | C++  | Calculate the vector norm on the VCK5000's AI Engines and use DMA Streaming for more efficient host-to-card communication. |

### Non-project Subfolders

| Subfolder                                | Description |
|------------------------------------------|-------------|
| [BSV-libraries](BSV-libraries)           | Bluespec libraries for building project PEs |
| [ProcessingElements](ProcessingElements) | Collection of PEs (currently only Counter PE used for benchmarking in examples of main repository) |

## Build Examples

Make sure to clone this repository recursively using

```
git clone --recursive https://github.com/esa-tu-darmstadt/tapasco-examples.git
```
Further build instructions are included in the READMEs of the examples in the respective subfolders.
