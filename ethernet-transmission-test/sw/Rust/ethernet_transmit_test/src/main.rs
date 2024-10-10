#[macro_use]
extern crate log;
extern crate snafu;
extern crate tapasco;

use std::collections::HashMap;
use std::io;
use std::mem::size_of;
use snafu::{ResultExt, Snafu};
use tapasco::device::{DataTransferAlloc, PEParameter};
use tapasco::tlkm::TLKM;
use structopt::StructOpt;

const RECEIVER_PE_NAME: &str = "esa.informatik.tu-darmstadt.de:user:EthernetReceiver:1.0";
const TRANSMITTER_PE_NAME: &str = "esa.informatik.tu-darmstadt.de:user:EthernetTransmitter:1.0";
const OUTPUT_BUFFER_SIZE: usize = 4 * 1024 * 1024 * 1024; // 4 GB

#[derive(Debug, Snafu)]
pub enum Error {
    #[snafu(display("Failed to initialize TLKM object: {}", source))]
    TLKMInit { source: tapasco::tlkm::Error },

    #[snafu(display("Failed to decode TLKM device: {}", source))]
    DeviceInit { source: tapasco::device::Error },

    #[snafu(display("Error while executing Job: {}", source))]
    JobError { source : tapasco::job::Error },

    #[snafu(display("Error while opening file: {}", source))]
    FileOpen { source: io::Error },
}

#[derive(StructOpt, Debug)]
struct ProgramOptions {
    #[structopt(short, long, help = "Size of input data in bytes", default_value = "16384")]
    input_size: usize,

    #[structopt(short, long, help = "Frame length in bytes", default_value = "8192")]
    frame_length: usize,

    #[structopt(short, long, help = "Runtime of receiver in seconds", default_value = "0.5")]
    runtime: f64,

    #[structopt(long, help = "MAC address of transmitter device", default_value = "399482290434")] // 399482290434 = 0x005D03000102
    src_mac: u64,

    #[structopt(long, help = "MAC address of receiver device", default_value = "399482294358")] // 399482294358 = 0x005D03001056
    dst_mac: u64,

    #[structopt(long, help = "Gap between transmitting frames in transmitter PE in cycles", default_value = "0")]
    gap_cycles: u64,
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

fn main() -> Result<()> {
    env_logger::init();

    let options = ProgramOptions::from_args();

    if options.input_size % options.frame_length != 0 {
        error!("Input size must be multiple of frame length");
        return Ok(());
    }
    if options.input_size % 4096 != 0 {
        error!("Input size must be multiple of 4096");
        return Ok(());
    }

    let tlkm = TLKM::new().context(TLKMInitSnafu {})?;
    let devices = tlkm.device_enum(&HashMap::new()).context(TLKMInitSnafu {})?;


    let mut receiver_pe_opt = None;
    let mut transmitter_pe_opt = None;
    let mut receiver_dev_mem = None;
    let mut transmitter_dev_mem = None;
    let mut receiver_dev_freq = 0.0;

    for mut dev in devices {
        debug!("{:?}", dev);
        dev.change_access(tapasco::tlkm::tlkm_access::TlkmAccessExclusive).context(DeviceInitSnafu {})?;
        if receiver_pe_opt.is_none() {
            if let Ok(id) = dev.get_pe_id(RECEIVER_PE_NAME) {
                debug!("Found EthernetReceiver PE");
                receiver_pe_opt = Some(dev.acquire_pe(id).context(DeviceInitSnafu {})?);
                receiver_dev_mem = Some(dev.default_memory().context(DeviceInitSnafu {})?);
                receiver_dev_freq = dev.design_frequency_mhz().context(DeviceInitSnafu {})? as f64;
            };
        }

        if transmitter_pe_opt.is_none() {
            if let Ok(id) = dev.get_pe_id(TRANSMITTER_PE_NAME) {
                debug!("Found EthernetTransmitter PE");
                transmitter_pe_opt = Some(dev.acquire_pe(id).context(DeviceInitSnafu {})?);
                transmitter_dev_mem = Some(dev.default_memory().context(DeviceInitSnafu {})?);
            }
        }
    }

    if receiver_pe_opt.is_none() {
        error!("Could not detect required EthernetReceiver PE.");
        return Ok(());
    }

    if transmitter_pe_opt.is_none() {
        error!("Could not detect required EthernetTransmitter PE.");
        return Ok(());
    }

    if receiver_dev_mem.is_none() || transmitter_dev_mem.is_none() {
        error!("Error while detecting device memories.");
        return Ok(());
    }
    let mut receiver_pe = receiver_pe_opt.unwrap();
    let mut transmitter_pe = transmitter_pe_opt.unwrap();

    let input = vec![0u8; options.input_size].into_boxed_slice();
    let input_ptr = input.as_ptr() as *mut u32;
    for i in 0..(options.input_size / size_of::<i32>()) {
        unsafe { *input_ptr.offset(i as isize) = i as u32; }
    }

    let output = vec![0u8; OUTPUT_BUFFER_SIZE].into_boxed_slice();

    let mut receiver_params = Vec::new();
    receiver_params.push(PEParameter::DataTransferAlloc(DataTransferAlloc {
        data: output,
        from_device: true,
        to_device: false,
        free: true,
        memory: receiver_dev_mem.unwrap(),
        fixed: None,
    }));
    let mut run_cycles: u64 = (options.runtime * receiver_dev_freq * 1e6) as u64;
    info!("Runtime: {}, Device Frequency: {}", options.runtime, receiver_dev_freq);
    info!("Run receiver PE for {} cycles", run_cycles);
    if run_cycles > u32::MAX as u64 {
        warn!("Use maximum run cycles for receiver PE");
        run_cycles = u32::MAX as u64;
    }
    receiver_params.push(PEParameter::Single64(run_cycles));
    receiver_params.push(PEParameter::Single64(options.frame_length as u64));
    receiver_params.push(PEParameter::Single64(options.src_mac));
    receiver_params.push(PEParameter::Single64(options.dst_mac));
    receiver_params.push(PEParameter::Single64(0xACAC));

    let mut transmitter_params = Vec::new();
    transmitter_params.push(PEParameter::DataTransferAlloc(DataTransferAlloc {
        data: input,
        from_device: false,
        to_device: true,
        free: true,
        memory: transmitter_dev_mem.unwrap(),
        fixed: None,
    }));
    transmitter_params.push(PEParameter::Single64(options.input_size as u64));
    transmitter_params.push(PEParameter::Single64(options.frame_length as u64));
    transmitter_params.push(PEParameter::Single64(options.gap_cycles));
    transmitter_params.push(PEParameter::Single64(options.src_mac));
    transmitter_params.push(PEParameter::Single64(options.dst_mac));
    transmitter_params.push(PEParameter::Single64(0xACAC));

    info!("Launch PEs");
    receiver_pe.start(receiver_params).context(JobSnafu {})?;
    transmitter_pe.start(transmitter_params).context(JobSnafu {})?;

    let (_r, _o) = transmitter_pe.release(true, false).context(JobSnafu {})?;
    info!("Transmitter PE released");
    let (result, out_vec) = receiver_pe.release(true, true).context(JobSnafu {})?;
    info!("Receiver PE released");

    let received_beat_count = result & 0xFFFFFFFF;
    let wrong_header_count = (result >> 32) & 0xFFF;
    let wrong_frame_len_count = (result >> 44) & 0xFFF;
    let drop_beat_error = (result >> 56) & 0x1;

    if (received_beat_count) != (options.input_size as u64 / 64) {
        error!("Received wrong number of beats ({} Byte vs. {} Byte", received_beat_count * 64, options.input_size);
    }
    if wrong_header_count != 0 {
        error!("Received {} wrong headers", wrong_header_count);
    }
    if wrong_frame_len_count != 0 {
        error!("Received {} frames with wrong length", wrong_frame_len_count);
    }
    if drop_beat_error != 0 {
        error!("Beats have been dropped due to backpressure from memory on receiving device...consider to increase gap_cycle parameter to reduce transmit rate");
    }

    let output_ptr = out_vec[0].as_ptr() as *mut u32;
    let mut false_value_count = 0;
    let mut first_wrong_index = None;
    for i in 0..(received_beat_count * 16) {
        unsafe {
            if *output_ptr.offset(i as isize) != i as u32 {
                false_value_count += 1;
                if first_wrong_index.is_none() {
                    first_wrong_index = Some(i);
                }
            }
        }
    }

    if let Some(idx) = first_wrong_index {
        error!("Encountered {} wrong values", false_value_count);
        let frame = idx * 4 / options.frame_length as u64;
        let beat = ((idx * 4) % options.frame_length as u64) / 64;
        error!("First wrong value in frame {} at beat {}", frame, beat);
    }
    Ok(())
}