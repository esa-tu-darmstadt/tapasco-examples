package NVMeReaderWriter;

import DReg::*;
import FIFO::*;
import FIFOF::*;
import BRAMFIFO::*;
import Vector::*;
import GetPut::*;

import BlueAXI::*;
import BlueLib::*;

typedef  12 CTRL_ADDR_WIDTH;
typedef  64 CTRL_DATA_WIDTH;
typedef  40 MEM_ADDR_WIDTH;
typedef 512 MEM_DATA_WIDTH;
typedef   1 MEM_ID_WIDTH;
typedef   0 MEM_USER_WIDTH;
typedef 512 STREAM_DATA_WIDTH;
typedef   0 STREAM_USER_WIDTH;

typedef struct {
    Bit#(64) ddrAddr;
    Bit#(64) nvmeAddr;
    Bit#(64) nrPages;
    Bit#(64) rw;
} NVMeCmdExt deriving (Bits, Eq, FShow);

typedef enum {READ = 0, WRITE = 1} NVMeCmdDir deriving (Bits, Eq, FShow);
typedef struct {
    Bit#(MEM_ADDR_WIDTH) ddrAddr;
    Bit#(64) nvmeAddr;
    Bit#(20) nrPages;
    NVMeCmdDir rw;
} NVMeCmd deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(MEM_ADDR_WIDTH) ddrAddr;
    Bit#(64) nvmeAddr;
    Bit#(20) nrPages;
} NVMeCmdRW deriving (Bits, Eq, FShow);

typedef enum {IDLE, REQUEST, WAIT, ENQUEUE} CmdEngineState deriving (Bits, Eq, FShow);
typedef enum {IDLE, RUNNING} State deriving (Bits, Eq, FShow);

interface NVMeReaderWriter;
    (* prefix = "S_AXI_CTRL" *)
    interface AXI4_Lite_Slave_Rd_Fab#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) s_ctrl_rd_fab;
    (* prefix = "S_AXI_CTRL" *)
    interface AXI4_Lite_Slave_Wr_Fab#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) s_ctrl_wr_fab;

    (* prefix = "M_AXI_MEM" *)
    interface AXI4_Master_Rd_Fab#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH, MEM_USER_WIDTH) m_mem_rd_fab;
    (* prefix = "M_AXI_MEM" *)
    interface AXI4_Master_Wr_Fab#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH, MEM_USER_WIDTH) m_mem_wr_fab;

    (* prefix = "M_NVME_READ_REQ" *)
    interface AXI4_Stream_Wr_Fab#(STREAM_DATA_WIDTH, STREAM_USER_WIDTH) m_nvme_rd_req_fab;
    (* prefix = "M_NVME_WRITE_REQ" *)
    interface AXI4_Stream_Wr_Fab#(STREAM_DATA_WIDTH, STREAM_USER_WIDTH) m_nvme_wr_req_fab;
    (* prefix = "S_NVME_READ_RSP" *)
    interface AXI4_Stream_Rd_Fab#(STREAM_DATA_WIDTH, STREAM_USER_WIDTH) s_nvme_rd_rsp_fab;
    (* prefix = "S_NVME_WRITE_RSP" *)
    interface AXI4_Stream_Rd_Fab#(8, STREAM_USER_WIDTH) s_nvme_wr_rsp_fab;

    (* always_ready, always_enabled *)
    method Bool intr();
endinterface

(* synthesize, default_clock_osc = "aclk", default_reset = "aresetn" *)
module mkNVMeReaderWriter(NVMeReaderWriter);
    let axiMemRd <- mkAXI4_Master_Rd(2, 2, False);
    let axiMemWr <- mkAXI4_Master_Wr(2, 2, 2, False);
    let axiNvmeRdReq <- mkAXI4_Stream_Wr(2);
    let axiNvmeWrReq <- mkAXI4_Stream_Wr(2);
    let axiNvmeRdRsp <- mkAXI4_Stream_Rd(2);
    let axiNvmeWrRsp <- mkAXI4_Stream_Rd(2);

    Reg#(Bool) startReg <- mkDReg(False);
    Reg#(Bit#(64)) cycleCount <- mkReg(0);
    Reg#(Bit#(MEM_ADDR_WIDTH)) cmdAddr <- mkReg(0);
    Reg#(Bit#(12)) nrCmds <- mkReg(0);
    List#(RegisterOperator#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH)) ops = Nil;
    ops = registerHandler('h00, startReg, ops);
    ops = registerHandlerRO('h10, cycleCount, ops);
    ops = registerHandler('h20, cmdAddr, ops);
    ops = registerHandler('h30, nrCmds, ops);
    let axiCtrlSlave <- mkGenericAxi4LiteSlave(ops, 2, 2);


    Reg#(State) state <- mkReg(IDLE);
    Reg#(CmdEngineState) cmdEngineState <- mkReg(IDLE);
    Reg#(Bit#(MEM_ADDR_WIDTH)) cmdEngineAddr <- mkReg(0);
    Reg#(Bit#(12)) currentCmdId <- mkReg(0);
    Reg#(Bit#(12)) nvmeReadCompletionCount <- mkReg(0);
    Reg#(Bit#(12)) nvmeWriteCompletionCount <- mkReg(0);
    rule initModule if (state == IDLE && startReg);
        state <= RUNNING;
        cmdEngineState <= REQUEST;
        cmdEngineAddr <= cmdAddr;
        currentCmdId <= 0;
        nvmeReadCompletionCount <= 0;
        nvmeWriteCompletionCount <= 0;
        printColorTimed(YELLOW, $format("[initModule]"));
    endrule

    /**
     * Command Engine
     */
    FIFOF#(NVMeCmd) cmdFifo <- mkFIFOF;
    Reg#(Bool) waitForCmd <- mkReg(False);

    // read two commands from DDR, only if both commands can be buffered to avoid dead blocking of AXI
    rule requestCmds if (cmdEngineState == REQUEST && !cmdFifo.notEmpty());
        let req = AXI4_Read_Rq {
            id: 1,
            addr: cmdEngineAddr,
            burst_length: 0,
            burst_size: B64,
            burst_type: INCR,
            lock: defaultValue,
            cache: defaultValue,
            prot: defaultValue,
            qos: defaultValue,
            region: 0,
            user: 0
        };
        axiMemRd.request.put(req);
        cmdEngineAddr <= cmdEngineAddr + 64;
        cmdEngineState <= WAIT;
        printColorTimed(YELLOW, $format("[requestCmds]"));
    endrule

    // receive two commands, directly enqueue the first command and buffer the second
    Reg#(NVMeCmd) cmdBuffer <- mkReg(?);
    rule receiveCmds if (cmdEngineState == WAIT && axiMemRd.snoop().id == 1);
        let r <- axi4_read_response(axiMemRd);
        Vector#(2, NVMeCmdExt) vExt = unpack(r);
        Vector#(2, NVMeCmd) v = newVector;
        for (Integer i = 0; i < 2; i = i + 1) begin
            v[i] = NVMeCmd {
                ddrAddr: truncate(vExt[i].ddrAddr),
                nvmeAddr: vExt[i].nvmeAddr,
                nrPages: truncate(vExt[i].nrPages),
                rw: unpack(truncate(vExt[i].rw))
            };
        end
        cmdFifo.enq(v[0]);
        cmdBuffer <= v[1];
        currentCmdId <= currentCmdId + 1;
        cmdEngineState <= ENQUEUE;
        printColorTimed(YELLOW, $format("[receiveCmds] cmds = ") + fshow(v[0]) + $format(", ") + fshow(v[1]));
    endrule

    // enqueue buffered command and check whether all commands have been read
    rule enqueueCmd if (cmdEngineState == ENQUEUE);
        // all commands have been read -> send Command Engine to idle
        if (currentCmdId == nrCmds || currentCmdId + 1 == nrCmds) begin
            cmdEngineState <= IDLE;
        end
        else begin
            cmdEngineState <= REQUEST;
            currentCmdId <= currentCmdId + 1;
        end

        // do not enqueue in case of odd number of total commands (all commands already enqueued)
        if (currentCmdId != nrCmds) begin
            cmdFifo.enq(cmdBuffer);
        end
    endrule

    FIFO#(NVMeCmdRW) readCmdFifo <- mkFIFO();
    rule sortReadCommands if (cmdFifo.first().rw == READ);
        let cmd = cmdFifo.first();
        cmdFifo.deq();
        readCmdFifo.enq(NVMeCmdRW {
            ddrAddr: cmd.ddrAddr,
            nvmeAddr: cmd.nvmeAddr,
            nrPages: cmd.nrPages
        });
    endrule

    FIFO#(NVMeCmdRW) writeCmdFifo <- mkSizedFIFO(4);
    rule sortWriteCommands if (cmdFifo.first().rw == WRITE);
        let cmd = cmdFifo.first();
        cmdFifo.deq();
        writeCmdFifo.enq(NVMeCmdRW {
            ddrAddr: cmd.ddrAddr,
            nvmeAddr: cmd.nvmeAddr,
            nrPages: cmd.nrPages
        });
    endrule

    /**
     * NVMe Read Engine
     */
    FIFO#(Tuple2#(Bit#(MEM_ADDR_WIDTH), Bit#(20))) inFlightReadCmdFifo <- mkSizedFIFO(4);
    FIFO#(Bit#(MEM_DATA_WIDTH)) nvmeReadDataFifo <- mkSizedBRAMFIFO(255);

    // send NVMe read request to TaPaSCo NVMeStreamer IP
    rule sendNvmeReadRequest;
        let readCmd = readCmdFifo.first();
        readCmdFifo.deq();
        inFlightReadCmdFifo.enq(tuple2(readCmd.ddrAddr, readCmd.nrPages));

        Bit#(64) lenInBytes = extend(readCmd.nrPages) << 12;
        let p = AXI4_Stream_Pkg {
            data: {0, lenInBytes, readCmd.nvmeAddr},
            user: 0,
            keep: unpack(-1),
            dest: 0,
            last: True
        };
        axiNvmeRdReq.pkg.put(p);
    endrule

    // receive and buffer data from NVMeStreamer
    Reg#(UInt#(6)) nvmeReadReceiveCount <- mkReg(0);
    FIFO#(Bit#(0)) nvmeReadTriggerMemWrite <- mkFIFO;
    rule receiveNvmeReadData;
        let r <- axiNvmeRdRsp.pkg.get();
        nvmeReadDataFifo.enq(r.data);
        nvmeReadReceiveCount <= nvmeReadReceiveCount + 1;
        if (nvmeReadReceiveCount == 63) begin
            nvmeReadTriggerMemWrite.enq(0);
        end
    endrule

    // issue write requests as full 4K bursts as soon as enough data is buffered
    Reg#(Maybe#(Bit#(MEM_ADDR_WIDTH))) currentDdrWriteAddr <- mkReg(tagged Invalid);
    Reg#(Bit#(20)) memWriteReqPageCount <- mkReg(0);
    FIFO#(Bit#(0)) inFlightMemWriteTransfers <- mkSizedFIFO(4);
    rule sendMemWriteRequest;
        nvmeReadTriggerMemWrite.deq();

        // check for active NVMe transfer or start new command
        let memWriteAddr = 0;
        if (currentDdrWriteAddr matches tagged Valid .a) begin
            memWriteAddr = a;
        end
        else begin
            memWriteAddr = tpl_1(inFlightReadCmdFifo.first());
        end
        axi4_write_addr(axiMemWr, memWriteAddr, 63);
        inFlightMemWriteTransfers.enq(0);

        // dequeue in-flight read command when sending last write request
        if (memWriteReqPageCount + 1 == tpl_2(inFlightReadCmdFifo.first())) begin
            inFlightReadCmdFifo.deq();
            currentDdrWriteAddr <= tagged Invalid;
            memWriteReqPageCount <= 0;
        end
        else begin
            currentDdrWriteAddr <= tagged Valid (memWriteAddr + 4096);
            memWriteReqPageCount <= memWriteReqPageCount + 1;
        end
    endrule

    // forward data to DDR
    Reg#(UInt#(6)) memWriteReqBeatCount <- mkReg(0);
    rule sendMemWriteData;
        let d = nvmeReadDataFifo.first();
        nvmeReadDataFifo.deq();
        Bool last = memWriteReqBeatCount == 63;
        axi4_write_data(axiMemWr, d, unpack(-1), last);
        memWriteReqBeatCount <= memWriteReqBeatCount + 1;
    endrule

    // process write responses from DDR
    rule discardMemWriteResponse;
        let r <- axi4_write_response(axiMemWr);
        inFlightMemWriteTransfers.deq();
        nvmeReadCompletionCount <= nvmeReadCompletionCount + 1;
    endrule

    /**
     * NVMe Write Engine
     */
    FIFO#(Bit#(MEM_DATA_WIDTH)) nvmeWriteDataFifo <- mkSizedBRAMFIFO(255);
    Reg#(Maybe#(Bit#(MEM_ADDR_WIDTH))) currentDdrReadAddr <- mkReg(tagged Invalid);
    Reg#(Bit#(20)) memReadReqPageCount <- mkReg(0);
    FIFO#(Bit#(0)) inFlightMemReadTransfers <- mkSizedFIFO(4);
    FIFO#(Bit#(64)) nextNVMeWriteCmdFifo <- mkFIFO;
    FIFO#(Bit#(26)) nextNVMeWriteCmdLenFifo <- mkFIFO;

    (* descending_urgency = "requestCmds, sendMemReadRequest" *)
    rule sendMemReadRequest;
        let cmd = writeCmdFifo.first();

        // check for active NVMe transfer or start new command
        let memReadAddr = 0;
        if (currentDdrReadAddr matches tagged Valid .a) begin
            memReadAddr = a;
        end
        else begin
            memReadAddr = cmd.ddrAddr;
            nextNVMeWriteCmdFifo.enq(cmd.nvmeAddr);
            nextNVMeWriteCmdLenFifo.enq(extend(cmd.nrPages) << 6);
        end
        axi4_read_data(axiMemRd, memReadAddr, 63);
        inFlightMemReadTransfers.enq(0);

        // dequeue in-flight write command when sending last read request
        if (memReadReqPageCount + 1 == cmd.nrPages) begin
            writeCmdFifo.deq();
            currentDdrReadAddr <= tagged Invalid;
            memReadReqPageCount <= 0;
        end
        else begin
            currentDdrReadAddr <= tagged Valid (memReadAddr + 4096);
            memReadReqPageCount <= memReadReqPageCount + 1;
        end
    endrule

    // receive and buffer data from DDR
    rule receiveMemReadData if (axiMemRd.snoop().id == 0);
        let r <- axiMemRd.response.get();
        nvmeWriteDataFifo.enq(r.data);
        if (r.last) begin
            inFlightMemReadTransfers.deq();
        end
    endrule

    // send write command to NVMeStreamer IP (only address)
    Reg#(Bool) sendNvmeWriteCmdSwitch <- mkReg(True);
    rule sendNvmeWriteCommand if (sendNvmeWriteCmdSwitch);
        let c = nextNVMeWriteCmdFifo.first();
        nextNVMeWriteCmdFifo.deq();
        let p = AXI4_Stream_Pkg {
            data: extend(c),
            user: 0,
            keep: unpack(-1),
            dest: 0,
            last: False
        };
        axiNvmeWrReq.pkg.put(p);
        sendNvmeWriteCmdSwitch <= False;
    endrule

    // send write data to NVMeStreamer IP
    Reg#(Bit#(26)) nvmeWriteDataCount <- mkReg(0);
    FIFO#(Bit#(0)) pendingNvmeWriteResponse <- mkFIFO;
    rule sendNvmeWriteData if (!sendNvmeWriteCmdSwitch);
        let d = nvmeWriteDataFifo.first();
        nvmeWriteDataFifo.deq();
        Bool last = nvmeWriteDataCount + 1 == nextNVMeWriteCmdLenFifo.first();
        let p = AXI4_Stream_Pkg {
            data: d,
            user: 0,
            keep: unpack(-1),
            dest: 0,
            last: last
        };
        axiNvmeWrReq.pkg.put(p);

        if (last) begin
            nextNVMeWriteCmdLenFifo.deq();
            nvmeWriteDataCount <= 0;
            pendingNvmeWriteResponse.enq(0);
            sendNvmeWriteCmdSwitch <= True;
        end
        else begin
            nvmeWriteDataCount <= nvmeWriteDataCount + 1;
        end
    endrule

    // process write responses from NVMeStreamer IP
    rule receivNvmeWriteResponse;
        let r <- axiNvmeWrRsp.pkg.get();
        pendingNvmeWriteResponse.deq();
        nvmeWriteCompletionCount <= nvmeWriteCompletionCount + 1;
    endrule

    // send interrupt after all commands have been completed
    Reg#(Bool) intrReg <- mkDReg(False);
    rule checkForCompletion if (state == RUNNING);
        let completions = nvmeReadCompletionCount + nvmeWriteCompletionCount;
        if (completions == nrCmds) begin
            intrReg <= True;
            state <= IDLE;
        end
    endrule

    interface s_ctrl_rd_fab = axiCtrlSlave.s_rd;
    interface s_ctrl_wr_fab = axiCtrlSlave.s_wr;
    interface m_mem_rd_fab = axiMemRd.fab;
    interface m_mem_wr_fab = axiMemWr.fab;
    interface m_nvme_rd_req_fab = axiNvmeRdReq.fab;
    interface m_nvme_wr_req_fab = axiNvmeWrReq.fab;
    interface s_nvme_rd_rsp_fab = axiNvmeRdRsp.fab;
    interface s_nvme_wr_rsp_fab = axiNvmeWrRsp.fab;
    interface intr = intrReg;
endmodule

endpackage
