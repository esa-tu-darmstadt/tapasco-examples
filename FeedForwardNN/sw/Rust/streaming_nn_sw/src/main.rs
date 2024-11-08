#[macro_use]
extern crate log;
extern crate snafu;
extern crate tapasco;

use std::collections::HashMap;
use std::fs::File;
use std::io;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::mem::size_of;
use std::time::Instant;
use snafu::{ResultExt, Snafu};
use tapasco::device::{DataTransferAlloc, DataTransferLocal, DataTransferStream, PEParameter};
use tapasco::tlkm::TLKM;
use structopt::StructOpt;
use tapasco::job::Job;
use statrs::statistics::Statistics;

const WEIGHT_STREAM_PE_NAME: &str = "esa.informatik.tu-darmstadt.de:user:WeightStreamer:1.0";
const DATA_STREAM_PE_NAME: &str = "esa.informatik.tu-darmstadt.de:user:DataStreamer:1.0";
const DATA_STREAM_MM_PE_NAME: &str = "esa.informatik.tu-darmstadt.de:user:DataStreamerMM:1.0";
const WEIGHT_STREAM_PART_IN_PE_NAME: &str = "esa.informatik.tu-darmstadt.de:user:WeightStreamerPartIn:1.0";
const WEIGHT_STREAM_PART_OUT_PE_NAME: &str = "esa.informatik.tu-darmstadt.de:user:WeightStreamerPartOut:1.0";
const DATA_STREAM_PART_IN_PE_NAME: &str = "esa.informatik.tu-darmstadt.de:user:DataStreamerPartIn:1.0";
const DATA_STREAM_PART_OUT_PE_NAME: &str = "esa.informatik.tu-darmstadt.de:user:DataStreamerPartOut:1.0";
const DATA_STREAM_MM_PART_IN_PE_NAME: &str = "esa.informatik.tu-darmstadt.de:user:DataStreamerMMPartIn:1.0";
const DATA_STREAM_MM_PART_OUT_PE_NAME: &str = "esa.informatik.tu-darmstadt.de:user:DataStreamerMMPartOut:1.0";
const STREAM_JOIN_PE_NAME: &str = "tu-darmstadt.de:user:StreamJoin:1.0";
const STREAM_SPLIT_PE_NAME: &str = "tu-darmstadt.de:user:StreamSplit:1.0";

const SAMPLE_SIZE: usize = 64;
const NUM_L0_STREAMS: usize = 32;
const NUM_L1_STREAMS: usize = 16;
const NUM_L2_STREAMS: usize = 16;
const NUM_WEIGHT_STREAMS: usize = NUM_L0_STREAMS + NUM_L1_STREAMS + NUM_L2_STREAMS;
const NUM_L0_WEIGHTS: usize = 64 * 128;
const NUM_L1_WEIGHTS: usize = 128 * 64;
const NUM_L2_WEIGHTS: usize = 64 * 64;
const NUM_L0_WEIGHTS_PER_ENGINE: usize = NUM_L0_WEIGHTS / NUM_L0_STREAMS;
const NUM_L1_WEIGHTS_PER_ENGINE: usize = NUM_L1_WEIGHTS / NUM_L1_STREAMS;
const NUM_L2_WEIGHTS_PER_ENGINE: usize = NUM_L2_WEIGHTS / NUM_L2_STREAMS;
const NUM_FEATURE_STREAMS: usize = 4;
const MAX_SAMPLES_BENCHMARK: usize = 4 * 1024 * 1024;

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
    #[structopt(short, long, help = "Number of samples", default_value = "4096")]
    num_samples: usize,

    #[structopt(short, long, help = "use memory mapped DataStreamerMM PE")]
    mm: bool,

    #[structopt(short, long, help = "split NN on two FPGAs")]
    split: bool,

    #[structopt(short, long, help = "run benchmark with different sample sizes")]
    benchmark: bool,

    #[structopt(short, long, help = "number of iteraions per sample size", default_value = "1")]
    iterations: usize,
}

#[derive(Debug)]
pub struct TimeResult {
    num_samples: usize,
    runtime_host: f64,
    runtime_device: f64,
    mm: bool,
    split: bool,
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

fn main() -> Result<()> {
    env_logger::init();

    let options = ProgramOptions::from_args();
    let max_samples = if options.benchmark {
        MAX_SAMPLES_BENCHMARK
    } else {
        options.num_samples
    };
    if options.num_samples % 32 != 0 {
        error!("Sample size must be multiple of 32 (batch size)");
        return Ok(())
    }

    let mut all_weights: Vec<Vec<f32>> = Vec::new();
    for i in 0..NUM_WEIGHT_STREAMS {
        let mut layer_idx = usize::MAX;
        let mut split_idx = usize::MAX;
        let mut casc_idx = usize::MAX;
        if i < NUM_L0_STREAMS {
            layer_idx = 0;
            split_idx = i / 4;
            casc_idx = i % 4;
        } else if i < (NUM_L0_STREAMS + NUM_L1_STREAMS) {
            layer_idx = 1;
            split_idx = (i - NUM_L0_STREAMS) / 4;
            casc_idx = i % 4;
        } else if i < (NUM_L0_STREAMS + NUM_L1_STREAMS + NUM_L2_STREAMS) {
            layer_idx = 2;
            split_idx = (i - NUM_L0_STREAMS - NUM_L1_STREAMS) / 4;
            casc_idx = i % 4;
        }
        let file_path = format!("Weights{}In{}_CASC_{}.txt", layer_idx, split_idx, casc_idx);
        let mut weights = read_input_file(file_path)?;
        if i < NUM_L0_STREAMS {
            weights.truncate(NUM_L0_WEIGHTS_PER_ENGINE);
        } else if i < (NUM_L0_STREAMS + NUM_L1_STREAMS) {
            weights.truncate(NUM_L1_WEIGHTS_PER_ENGINE);
        } else if i < (NUM_L0_STREAMS + NUM_L1_STREAMS + NUM_L2_STREAMS) {
            weights.truncate(NUM_L2_WEIGHTS_PER_ENGINE);
        }
        all_weights.push(weights);
    }
    let max_weight_len = match all_weights.iter().map(|w| { w.len()}).max() {
        Some(m) => m,
        None => {
            error!("No weights read in");
            return Ok(());
        }
    };

    info!("Max weights length: {}", max_weight_len);
    info!("Number of weight arrays: {}", all_weights.len());

    let mut input_buffer = Vec::new();

    // in case we use the memory mapped version feature data must be pre-sorted
    // split in four buffers, this is already done in the input files
    if options.mm {
        let mut feature_samples: Vec<Vec<f32>> = Vec::new();
        for i in 0..NUM_FEATURE_STREAMS {
            let file_path = format!("Features0In_CASC_{}.txt", i);
            let mut data = read_input_file(file_path)?;
            data.truncate(max_samples * SAMPLE_SIZE / NUM_FEATURE_STREAMS);
            feature_samples.push(data);
        }
        for s in feature_samples.iter() {
            if s.len() != feature_samples[0].len() {
                error!("Unequal number of samples in feature input files");
                return Ok(())
            }
        }
        for s in feature_samples.iter() {
            input_buffer.push(prepare_input_buffer(max_samples * SAMPLE_SIZE / NUM_FEATURE_STREAMS, s.as_slice()));
        }
    }
    // in the streaming case we read all data from one input file and have only one stream
    // to the device, sorting and splitting is done in the DataStreamer PE
    else {
        let mut sample_data: Vec<f32> = read_input_file("InputData.txt".to_string())?;
        sample_data.truncate(max_samples * SAMPLE_SIZE);
        input_buffer.push(prepare_input_buffer(max_samples * SAMPLE_SIZE, sample_data.as_slice()));
    }

    let mut sample_sizes = Vec::new();
    if options.benchmark {
        let mut s = 32;
        loop {
            if s > MAX_SAMPLES_BENCHMARK {
                break;
            }
            sample_sizes.push(s);
            s *= 2;
        }
    } else {
        info!("Run with {} samples ({} features, {} MB)",
        options.num_samples, options.num_samples * SAMPLE_SIZE,
        options.num_samples * SAMPLE_SIZE * size_of::<f32>() / 1024 / 1024);
        sample_sizes.push(options.num_samples);
    }
    let mut time_results = Vec::new();

    let tlkm = TLKM::new().context(TLKMInitSnafu {})?;
    let devices = tlkm.device_enum(&HashMap::new()).context(TLKMInitSnafu {})?;

    // ---------------------------------------------------------------------------------------------
    // ---------------------------------------------------------------------------------------------
    // Split version on 2 FPGAs
    // ---------------------------------------------------------------------------------------------
    // ---------------------------------------------------------------------------------------------
    if options.split {
        let mut weight_streamer_part_in_pe = None;
        let mut weight_streamer_part_out_pe = None;
        let mut data_streamer_part_in_pe = None;
        let mut data_streamer_part_out_pe = None;
        let mut data_streamer_mm_part_in_pe = None;
        let mut data_streamer_mm_part_out_pe = None;
        let mut stream_join_pe = None;
        let mut stream_split_pe = None;
        let mut dev_in_mem = None;
        let mut dev_out_mem = None;

        for mut dev in devices {
            debug!("{:?}", dev);
            dev.change_access(tapasco::tlkm::tlkm_access::TlkmAccessExclusive).context(DeviceInitSnafu {})?;
            if weight_streamer_part_in_pe.is_none() {
                if let Ok(id) = dev.get_pe_id(WEIGHT_STREAM_PART_IN_PE_NAME) {
                    debug!("Found WeightStreamerPartIn");
                    weight_streamer_part_in_pe = Some(dev.acquire_pe(id).context(DeviceInitSnafu {})?);
                    if let Ok(ids) = dev.get_pe_id(STREAM_JOIN_PE_NAME) {
                        stream_join_pe = Some(dev.acquire_pe(ids).context(DeviceInitSnafu {})?);
                    }
                    dev_in_mem = Some(dev.default_memory().context(DeviceInitSnafu {})?);
                    if options.mm {
                        if let Ok(id2) = dev.get_pe_id(DATA_STREAM_MM_PART_IN_PE_NAME) {
                            data_streamer_mm_part_in_pe = Some(dev.acquire_pe(id2).context(DeviceInitSnafu {})?);
                        }
                    } else {
                        if let Ok(id2) = dev.get_pe_id(DATA_STREAM_PART_IN_PE_NAME) {
                            data_streamer_part_in_pe = Some(dev.acquire_pe(id2).context(DeviceInitSnafu {})?);
                        }
                    }
                };
            }

            if weight_streamer_part_out_pe.is_none() {
                if let Ok(id) = dev.get_pe_id(WEIGHT_STREAM_PART_OUT_PE_NAME) {
                    debug!("Found WeightStreamerPartOut");
                    weight_streamer_part_out_pe = Some(dev.acquire_pe(id).context(DeviceInitSnafu {})?);
                    if let Ok(ids) = dev.get_pe_id(STREAM_SPLIT_PE_NAME) {
                        stream_split_pe = Some(dev.acquire_pe(ids).context(DeviceInitSnafu {})?);
                    }
                    dev_out_mem = Some(dev.default_memory().context(DeviceInitSnafu {})?);
                    if options.mm {
                        if let Ok(id2) = dev.get_pe_id(DATA_STREAM_MM_PART_OUT_PE_NAME) {
                            data_streamer_mm_part_out_pe = Some(dev.acquire_pe(id2).context(DeviceInitSnafu {})?);
                        }
                    } else {
                        if let Ok(id2) = dev.get_pe_id(DATA_STREAM_PART_OUT_PE_NAME) {
                            data_streamer_part_out_pe = Some(dev.acquire_pe(id2).context(DeviceInitSnafu {})?);
                        }
                    }
                }
            }
        }

        if weight_streamer_part_in_pe.is_none() || weight_streamer_part_out_pe.is_none() {
            error!("Could not detect required WeightStreamer PEs.");
            return Ok(());
        }

        if stream_split_pe.is_none() {
            error!("Could not detect StreamSplit PE.");
            return Ok(());
        }

        if stream_join_pe.is_none() {
            error!("Could not detect StreamJoin PE.");
            return Ok(());
        }

        let dev_in_weights = &all_weights[0..(NUM_L0_STREAMS + NUM_L1_STREAMS)];
        let dev_out_weights = &all_weights[(NUM_L0_STREAMS + NUM_L1_STREAMS)..NUM_WEIGHT_STREAMS];

        write_weights_to_pe(&mut weight_streamer_part_in_pe.unwrap(), dev_in_weights)?;
        write_weights_to_pe(&mut weight_streamer_part_out_pe.unwrap(), dev_out_weights)?;

        let mut stream_join_pe_unwrapped = stream_join_pe.unwrap();
        let mut stream_split_pe_unwrapped = stream_split_pe.unwrap();

        let mut stream_join_params = Vec::new();
        stream_join_params.push(PEParameter::Single64(0));
        stream_join_params.push(PEParameter::Single64(0));
        stream_join_params.push(PEParameter::Single64(128));
        stream_join_params.push(PEParameter::Single64(0xAAAA));
        stream_join_params.push(PEParameter::Single64(100));
        stream_join_pe_unwrapped.start(stream_join_params).context(JobSnafu {})?;
        let (_r, _v) = stream_join_pe_unwrapped.release(true, false).context(JobSnafu {})?;

        let mut stream_split_params = Vec::new();
        stream_split_params.push(PEParameter::Single64(0));
        stream_split_params.push(PEParameter::Single64(0));
        stream_split_params.push(PEParameter::Single64(128));
        stream_split_params.push(PEParameter::Single64(0xAAAA));
        stream_split_pe_unwrapped.start(stream_split_params).context(JobSnafu {})?;

        // ---------------------------------------------
        // Memory mapped version (2 FPGAs)
        // ---------------------------------------------
        if options.mm {
            if data_streamer_mm_part_in_pe.is_none() || data_streamer_mm_part_out_pe.is_none() {
                error!("Could not detect required DataStreamerMM PEs.");
                return Ok(());
            }
            let mut data_streamer_mm_part_in_pe_unwrapped = data_streamer_mm_part_in_pe.unwrap();
            let mut data_streamer_mm_part_out_pe_unwrapped = data_streamer_mm_part_out_pe.unwrap();
            let dev_in_mem_unwrapped = dev_in_mem.unwrap();
            let dev_out_mem_unwrapped = dev_out_mem.unwrap();

            for sample_size_i in sample_sizes.iter() {
                let sample_size = *sample_size_i;
                info!("Perform runs with {} samples", sample_size);
                for it in 0..options.iterations {
                    if it % 50 == 0 {
                        info!(".");
                    }
                    let mut pe_in_params = Vec::new();
                    pe_in_params.push(PEParameter::Single64(sample_size as u64));
                    let input_buffer_size = sample_size * SAMPLE_SIZE / NUM_FEATURE_STREAMS * size_of::<f32>();
                    //for i in 0..NUM_FEATURE_STREAMS {
                    for b in input_buffer.iter() {
                        let mut sample_vec = vec![0u8; input_buffer_size];
                        sample_vec.copy_from_slice(&b[0..input_buffer_size]);
                        let sample_vec_box = sample_vec.into_boxed_slice();
                        pe_in_params.push(PEParameter::DataTransferAlloc(DataTransferAlloc {
                            data: sample_vec_box,
                            from_device: false,
                            to_device: true,
                            free: true,
                            memory: dev_in_mem_unwrapped.clone(),
                            fixed: None,
                        }));
                    }

                    let mut pe_out_params = Vec::new();
                    pe_out_params.push(PEParameter::Single64(sample_size as u64));
                    let buf_out = vec![0u8; sample_size * size_of::<f32>()].into_boxed_slice();
                    pe_out_params.push(PEParameter::DataTransferAlloc(DataTransferAlloc {
                        data: buf_out,
                        from_device: true,
                        to_device: false,
                        free: true,
                        memory: dev_out_mem_unwrapped.clone(),
                        fixed: None,
                    }));

                    debug!("Launch PEs");
                    let start = Instant::now();
                    data_streamer_mm_part_out_pe_unwrapped.start(pe_out_params).context(JobSnafu {})?;
                    data_streamer_mm_part_in_pe_unwrapped.start(pe_in_params).context(JobSnafu {})?;

                    let (_r_in, _v_in) = data_streamer_mm_part_in_pe_unwrapped.release(false, true).context(JobSnafu {})?;
                    let (_r_out, v_out) = data_streamer_mm_part_out_pe_unwrapped.release(false, true).context(JobSnafu {})?;
                    let end = Instant::now();
                    debug!("PEs finished");

                    let duration = end - start;
                    let runtime_host = duration.as_secs_f64();
                    debug!("Runtime on host: {} s", runtime_host);
                    time_results.push(TimeResult {
                        num_samples: sample_size,
                        runtime_host,
                        runtime_device: -1.0,
                        mm: true,
                        split: true,
                    });

                    if it == options.iterations - 1 {
                        let mut res_data = Vec::new();
                        let v_out_ptr = v_out[0].as_ptr() as *mut f32;
                        for i in 0..sample_size {
                            unsafe {
                                res_data.push(*v_out_ptr.offset(i as isize))
                            }
                        }
                        let result_file_path = format!("result_{}_samples.txt", sample_size);
                        write_output_file(result_file_path, res_data)?;
                    }
                }
            }
        }
        // ---------------------------------------------
        // Streaming version (2 FPGAs)
        // ----------------------------------------------
        else {
            if data_streamer_part_in_pe.is_none() || data_streamer_part_out_pe.is_none() {
                error!("Could not detect required DataStreamer PEs.");
                return Ok(());
            }
            let mut data_streamer_part_in_pe_unwrapped = data_streamer_part_in_pe.unwrap();
            let mut data_streamer_part_out_pe_unwrapped = data_streamer_part_out_pe.unwrap();
            let dev_in_mem_unwrapped = dev_in_mem.unwrap();
            let dev_out_mem_unwrapped = dev_out_mem.unwrap();

            for sample_size_i in sample_sizes.iter() {
                let sample_size = *sample_size_i;
                info!("Perform runs with {} samples", sample_size);
                for it in 0..options.iterations {
                    if it % 50 == 0 {
                        info!(".");
                    }
                    let input_buffer_size = sample_size * SAMPLE_SIZE * size_of::<f32>();
                    let mut sample_vec = vec![0u8; input_buffer_size];
                    sample_vec.copy_from_slice(&input_buffer[0][0..input_buffer_size]);
                    let sample_vec_box = sample_vec.into_boxed_slice();
                    let buf_out = vec![0u8; sample_size * size_of::<f32>()].into_boxed_slice();

                    let mut pe_in_params = Vec::new();
                    pe_in_params.push(PEParameter::Single64(sample_size as u64));
                    pe_in_params.push(PEParameter::DataTransferStream(DataTransferStream {
                        data: sample_vec_box,
                        c2h: false,
                        memory: dev_in_mem_unwrapped.clone(),
                    }));

                    let mut pe_out_params = Vec::new();
                    pe_out_params.push(PEParameter::Single64(sample_size as u64));
                    pe_out_params.push(PEParameter::DataTransferStream(DataTransferStream {
                        data: buf_out,
                        c2h: true,
                        memory: dev_out_mem_unwrapped.clone(),
                    }));

                    debug!("Launch PEs");
                    let start = Instant::now();
                    data_streamer_part_out_pe_unwrapped.start(pe_out_params).context(JobSnafu {})?;
                    data_streamer_part_in_pe_unwrapped.start(pe_in_params).context(JobSnafu {})?;

                    let (_r_in, _v_in) = data_streamer_part_in_pe_unwrapped.release(false, true).context(JobSnafu {})?;
                    let (_r_out, v_out) = data_streamer_part_out_pe_unwrapped.release(false, true).context(JobSnafu {})?;
                    let end = Instant::now();
                    debug!("PEs finished");

                    let duration = end - start;
                    let runtime_host = duration.as_secs_f64();
                    debug!("Runtime on host: {} s", runtime_host);

                    time_results.push(TimeResult {
                        num_samples: sample_size,
                        runtime_host,
                        runtime_device: -1.0,
                        mm: false,
                        split: true,
                    });

                    if it == options.iterations - 1 {
                        let mut res_data = Vec::new();
                        let v_out_ptr = v_out[0].as_ptr() as *mut f32;
                        for i in 0..sample_size {
                            unsafe {
                                res_data.push(*v_out_ptr.offset(i as isize))
                            }
                        }
                        let result_file_path = format!("result_{}_samples.txt", sample_size);
                        write_output_file(result_file_path, res_data)?;
                    }
                }
            }
        }
    }
    // ---------------------------------------------------------------------------------------------
    // ---------------------------------------------------------------------------------------------
    // Single FPGA version
    // ---------------------------------------------------------------------------------------------
    // ---------------------------------------------------------------------------------------------
    else {
        for mut dev in devices {
            dev.change_access(tapasco::tlkm::tlkm_access::TlkmAccessExclusive).context(DeviceInitSnafu {})?;
            let weight_stream_id = match dev.get_pe_id(WEIGHT_STREAM_PE_NAME) {
                Ok(n) => n,
                Err(_) => {
                    warn!("Could not retrieve WeightStreamer ID...trying next device");
                    continue;
                }
            };
            let data_stream_id = if options.mm {
                match dev.get_pe_id(DATA_STREAM_MM_PE_NAME) {
                    Ok(n) => n,
                    Err(_) => {
                        warn!("Could not retrieve DataStreamerMM ID...trying next device");
                        continue;
                    }
                }
            } else {
                match dev.get_pe_id(DATA_STREAM_PE_NAME) {
                    Ok(n) => n,
                    Err(_) => {
                        warn!("Could not retrieve DataStreamer ID...trying next device");
                        continue;
                    }
                }
            };

            // write all weights in one buffer to write it into the WeightStreamer PE
            // address space of each weight stream is aligned to largest stream
            info!("Write weights into local memory of WeightStreaner");
            let weight_buf = vec![0u8; all_weights.len() * max_weight_len * size_of::<f32>()];
            let weight_buf_box = weight_buf.into_boxed_slice();
            let weight_buf_ptr = weight_buf_box.as_ptr() as *mut f32;
            for (i, w_vec) in all_weights.iter().enumerate() {
                let base = i * max_weight_len;
                for (j, w) in w_vec.iter().enumerate() {
                    unsafe {
                        *weight_buf_ptr.offset((base + j) as isize) = *w;
                    }
                }
            }

            let mut weight_stream_params = Vec::new();
            weight_stream_params.push(PEParameter::DataTransferLocal(DataTransferLocal {
                data: weight_buf_box,
                from_device: false,
                to_device: true,
                free: true,
                fixed: None,
            }));
            let mut weight_stream_pe = dev.acquire_pe(weight_stream_id).context(DeviceInitSnafu {})?;
            weight_stream_pe.start(weight_stream_params).context(JobSnafu {})?;
            weight_stream_pe.release(true, false).context(JobSnafu {})?;

            for sample_size_i in sample_sizes.iter() {
                let sample_size = *sample_size_i;
                info!("Perform runs with sample size {}", sample_size);
                for it in 0..options.iterations {
                    if it % 50 == 0 {
                        info!(".");
                    }
                    let mut data_streamer_params = Vec::new();
                    data_streamer_params.push(PEParameter::Single64(sample_size as u64));
                    if options.mm {
                        let input_buf_size = sample_size * SAMPLE_SIZE / NUM_FEATURE_STREAMS * size_of::<f32>();
                        for s in input_buffer.iter() {
                            let mut sample_vec = vec![0u8; input_buf_size];
                            sample_vec.copy_from_slice(&s[0..input_buf_size]);
                            let sample_vec_box = sample_vec.into_boxed_slice();
                            data_streamer_params.push(PEParameter::DataTransferAlloc(DataTransferAlloc {
                                data: sample_vec_box,
                                from_device: false,
                                to_device: true,
                                free: true,
                                memory: dev.default_memory().context(DeviceInitSnafu {})?,
                                fixed: None,
                            }));
                        }
                        let result_buf = vec![0u8; sample_size * size_of::<f32>()];
                        let result_buf_box = result_buf.into_boxed_slice();
                        data_streamer_params.push(PEParameter::DataTransferAlloc(DataTransferAlloc {
                            data: result_buf_box,
                            from_device: true,
                            to_device: false,
                            free: true,
                            memory: dev.default_memory().context(DeviceInitSnafu {})?,
                            fixed: None,
                        }));
                    } else {
                        let input_buf_size = sample_size * SAMPLE_SIZE * size_of::<f32>();
                        let mut sample_vec = vec![0u8; input_buf_size];
                        sample_vec.copy_from_slice(&input_buffer[0][0..input_buf_size]);
                        //let batch_buf_box = input_buffer[0].clone();
                        let sample_vec_box = sample_vec.into_boxed_slice();
                        let result_buf = vec![0u8; sample_size * size_of::<f32>()];
                        let result_buf_boxed = result_buf.into_boxed_slice();

                        data_streamer_params.push(PEParameter::DataTransferStream(DataTransferStream {
                            data: result_buf_boxed,
                            c2h: true,
                            memory: dev.default_memory().context(DeviceInitSnafu {})?,
                        }));
                        data_streamer_params.push(PEParameter::DataTransferStream(DataTransferStream {
                            data: sample_vec_box,
                            c2h: false,
                            memory: dev.default_memory().context(DeviceInitSnafu {})?,
                        }));
                    }
                    let mut data_stream_pe = dev.acquire_pe(data_stream_id).context(DeviceInitSnafu {})?;

                    debug!("Launch PE");
                    let start = Instant::now();
                    data_stream_pe.start(data_streamer_params).context(JobSnafu {})?;
                    let (ret, res_buf) = data_stream_pe.release(true, true).context(JobSnafu {})?;
                    let end = Instant::now();
                    debug!("PE finished");
                    let duration = end - start;
                    let runtime_host = duration.as_secs_f64();
                    let runtime_dev: f64 = if options.mm {
                        ret as f64 / (dev.design_frequency_mhz().unwrap() as f64 * 1e6)
                    } else {
                        ret as f64 / 250000000.0f64
                    };
                    time_results.push(TimeResult {
                        num_samples: sample_size,
                        runtime_host,
                        runtime_device: runtime_dev,
                        mm: options.mm,
                        split: false,
                    });
                    debug!("Runtime host: {} s", runtime_host);
                    debug!("Runtime device: {} s", runtime_dev);

                    // copy result vector
                    if it == options.iterations - 1 {
                        let mut res_vec = Vec::new();
                        let ptr = res_buf[0].as_ptr() as *const f32;
                        for i in 0..(res_buf[0].len() / 4) {
                            unsafe {
                                res_vec.push(*ptr.offset(i as isize));
                            }
                        }
                        let res_file_path = format!("result_{}_samples.txt", sample_size);
                        write_output_file(res_file_path, res_vec)?;
                    }
                }
            }
            break;
        }
    }

    for t in time_results.iter() {
        info!("{:?}", t);
    }

    let mut means = Vec::new();
    for s in sample_sizes {
        let mean_host = time_results
                        .iter()
                        .filter(|r| r.num_samples == s)
                        .map(|r| r.runtime_host)
                        .collect::<Vec<f64>>()
                        .as_slice()
                        .mean();
        let mean_dev = time_results
            .iter()
            .filter(|r| r.num_samples == s)
            .map(|r| r.runtime_device)
            .collect::<Vec<f64>>()
            .as_slice()
            .mean();
        means.push(TimeResult {
            num_samples: s,
            runtime_host: mean_host,
            runtime_device: mean_dev,
            mm: options.mm,
            split: options.split,
        });
    }
    write_time_results_csv("time_results.csv",time_results)?;
    write_time_results_csv("time_means.csv", means)?;

    Ok(())
}

fn write_weights_to_pe(weight_streamer_pe: &mut Job, weights: &[Vec<f32>]) -> Result<(), Error> {
    info!("Write weights into local memories of WeightStreamer PEs.");
    let max_len = weights.iter().map(|s| s.len()).max().unwrap();
    let weights_in_buf = vec![0u8; weights.len() * max_len * size_of::<f32>()];
    let weights_in_buf_boxed = weights_in_buf.into_boxed_slice();
    let weights_in_ptr = weights_in_buf_boxed.as_ptr() as *mut f32;
    for (i, w_vec) in weights.iter().enumerate() {
        let base = i * max_len;
        for (j, w) in w_vec.iter().enumerate() {
            unsafe {
                *weights_in_ptr.offset((base + j) as isize) = *w;
            }
        }
    }
    let mut pe_params = Vec::new();
    pe_params.push(PEParameter::DataTransferLocal(DataTransferLocal {
        data: weights_in_buf_boxed,
        from_device: false,
        to_device: true,
        free: true,
        fixed: None,
    }));
    weight_streamer_pe.start(pe_params).context(JobSnafu {})?;
    weight_streamer_pe.release(true, false).context(JobSnafu {})?;
    Ok(())
}

fn prepare_input_buffer(num_elements: usize, samples: &[f32]) -> Box<[u8]> {
    let batch_buf = vec![0u8; num_elements * size_of::<f32>()];
    let batch_buf_box = batch_buf.into_boxed_slice();
    let batch_buf_ptr = batch_buf_box.as_ptr() as *mut f32;
    for i in 0..(num_elements) {
        unsafe {
            *batch_buf_ptr.offset(i as isize) = samples[i % samples.len()];
        }
    }
    return batch_buf_box;
}

fn read_input_file(file_path: String) -> Result<Vec<f32>> {
    info!("Read data from file: {}", file_path);
    let file = File::open(file_path).context(FileOpenSnafu {})?;
    let reader = BufReader::new(file);

    let mut weights= Vec::new();
    for line in reader.lines() {
        for word in line.unwrap().split_whitespace() {
            weights.push(word.parse::<f32>().unwrap());
        }
    }
    Ok(weights)
}

fn write_output_file(file_path: String, vals: Vec<f32>) -> Result<()>{
    info!("Write data to file: {}", file_path);
    {
        let file = File::create(file_path).context(FileOpenSnafu {})?;
        //let file = File::open(file_path).context(FileOpenSnafu {})?;
        let mut writer = BufWriter::new(file);

        for i in 0..(vals.len() / 4) {
            let base = i * 4;
            writeln!(writer, "{} {} {} {}",
                     vals[base],
                     vals[base + 1],
                     vals[base + 2],
                     vals[base + 3])
                .context(FileOpenSnafu {})?;
        }
    }
    info!("Data written to file");
    Ok(())
}

fn write_time_results_csv(file_path: &str, result_vec: Vec<TimeResult>) -> Result<()> {
    let file = File::create(file_path).context(FileOpenSnafu {})?;
    let mut writer = BufWriter::new(file);
    writeln!(writer, "Samples,Runtime host,Runtime device,MM,Split").context(FileOpenSnafu {})?;
    for r in result_vec.iter() {
        writeln!(writer, "{},{},{},{},{}",
                 r.num_samples,
                 r.runtime_host,
                 r.runtime_device,
                 r.mm,
                 r.split)
            .context(FileOpenSnafu {})?;
    }
    Ok(())
}
