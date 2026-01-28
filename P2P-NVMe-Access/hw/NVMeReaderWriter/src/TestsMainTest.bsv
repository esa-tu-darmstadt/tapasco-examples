package TestsMainTest;

import StmtFSM::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;
import ClientServer::*;
import Vector::*;

import TestHelper::*;
import BlueLib::*;
import BlueAXI::*;
import NVMeReaderWriter::*;

(* synthesize *)
module [Module] mkTestsMainTest(TestHelper::TestHandler);

    AXI4_Lite_Master_Rd#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) axiCtrlRd <- mkAXI4_Lite_Master_Rd(2);
    AXI4_Lite_Master_Wr#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) axiCtrlWr <- mkAXI4_Lite_Master_Wr(2);
    AXI4_Stream_Rd#(STREAM_DATA_WIDTH, STREAM_USER_WIDTH) axiNvmeRdReq <- mkAXI4_Stream_Rd(2);
    AXI4_Stream_Rd#(STREAM_DATA_WIDTH, STREAM_USER_WIDTH) axiNvmeWrReq <- mkAXI4_Stream_Rd(2);
    AXI4_Stream_Wr#(STREAM_DATA_WIDTH, STREAM_USER_WIDTH) axiNvmeRdRsp <- mkAXI4_Stream_Wr(2);
    AXI4_Stream_Wr#(                8, STREAM_USER_WIDTH) axiNvmeWrRsp <- mkAXI4_Stream_Wr(2);
    BRAM_Configure cfg = defaultValue;
    BRAM2PortBE#(Bit#(30), Bit#(512), 64) bram <- mkBRAM2ServerBE(cfg);
    BlueAXIBRAM#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH) axiBram <- mkBlueAXIBRAM(bram.portA);
    NVMeReaderWriter dut <- mkNVMeReaderWriter();
    mkConnection(axiCtrlRd.fab, dut.s_ctrl_rd_fab);
    mkConnection(axiCtrlWr.fab, dut.s_ctrl_wr_fab);
    mkConnection(dut.m_mem_rd_fab, axiBram.rd);
    mkConnection(dut.m_mem_wr_fab, axiBram.wr);
    mkConnection(dut.m_nvme_rd_req_fab, axiNvmeRdReq.fab);
    mkConnection(dut.m_nvme_wr_req_fab, axiNvmeWrReq.fab);
    mkConnection(axiNvmeRdRsp.fab, dut.s_nvme_rd_rsp_fab);
    mkConnection(axiNvmeWrRsp.fab, dut.s_nvme_wr_rsp_fab);

    Reg#(Bool) lastIntr <- mkReg(False);
    rule readIntr;
        lastIntr <= dut.intr();
    endrule

    Stmt s = {
        seq
            $display("Hello World from the testbench.");

        endseq
    };
    FSM testFSM <- mkFSM(s);

    Reg#(Bit#(4)) nvmeReadID <- mkReg(0);
    Reg#(Bit#(508)) nvmeReadCount <- mkReg(0);
    Reg#(Bit#(64)) nvmeReadAddress <- mkReg(0);
    Reg#(Bit#(64)) nvmeReadLength <- mkReg(0);
    Stmt nvmeReadHandlingStmt = {
        seq
            // check read request
            action
                let req <- axiNvmeRdReq.pkg.get();
                if (req.data[63:0] != nvmeReadAddress) begin
                    printColorTimed(RED, $format("ERROR: Wrong NVMe read address (0x%x) for transfer #%0d", req.data[63:0], nvmeReadID));
                    $finish;
                end
                if (req.data[127:64] != nvmeReadLength) begin
                    printColorTimed(RED, $format("ERROR: Wrong NVMe read length (0x%x) for transfer #%0d", req.data[127:64], nvmeReadID));
                    $finish;
                end
            endaction
            printColorTimed(BLUE, $format("Starting to send data for NVMe read transfer #%0d (addr = 0x%x, len = 0x%x)", nvmeReadID, nvmeReadAddress, nvmeReadLength));
            delay(137);
            nvmeReadCount <= 0;
            while (truncate(nvmeReadCount) < (nvmeReadLength >> 6)) seq
                action
                    Bool last = truncate(nvmeReadCount) == (nvmeReadLength >> 6) - 1;
                    let pkg = AXI4_Stream_Pkg {
                        data: {nvmeReadID, nvmeReadCount},
                        user: 0,
                        keep: unpack(-1),
                        dest: 0,
                        last: last
                    };
                    axiNvmeRdRsp.pkg.put(pkg);
                    nvmeReadCount <= nvmeReadCount + 1;
                endaction
            endseq
            printColorTimed(BLUE, $format("Handling of NVMe read transfer #%d completed", nvmeReadID));
        endseq
    };
    FSM nvmeReadHandlingFSM <- mkFSM(nvmeReadHandlingStmt);

    Reg#(Bit#(4)) nvmeWriteID <- mkReg(0);
    Reg#(Bit#(508)) nvmeWriteCount <- mkReg(0);
    Reg#(Bit#(64)) nvmeWriteAddress <- mkReg(0);
    Reg#(Bit#(64)) nvmeWriteLength <- mkReg(0);
    Reg#(Bool) breakLoop <- mkReg(False);
    Stmt nvmeWriteHandlingStmt = {
        seq
            // check write request
            action
                let req <- axiNvmeWrReq.pkg.get();
                if (req.data[63:0] != nvmeWriteAddress) begin
                    printColorTimed(RED, $format("ERROR: Wrong NVMe write address (0x%x) for transfer #%0d", req.data[63:0], nvmeWriteID));
                    $finish;
                end
            endaction
            printColorTimed(BLUE, $format("Start receiving data for NVMe write transfer #%0d (addr = 0x%x, len = 0x%x)", nvmeWriteID, nvmeWriteAddress, nvmeWriteLength));
            nvmeWriteCount <= 0;
            breakLoop <= False;
            while (truncate(nvmeWriteCount) <= (nvmeWriteLength >> 6) && !breakLoop) seq
                action
                    let p <- axiNvmeWrReq.pkg.get();
                    let data = p.data;
                    if (data[511:508] != nvmeWriteID) begin
                        printColorTimed(RED, $format("ERROR: Wrong ID in write data (#%0d vs. #%0d)", data[511:508], nvmeWriteID));
                        $finish;
                    end
                    if (data[507:0] != nvmeWriteCount) begin
                        printColorTimed(RED, $format("ERROR: Wrong count in write data (0x%x vs. 0x%x)", data[511:508], nvmeWriteCount));
                        $finish;
                    end
                    if (p.last) begin breakLoop <= True; end
                    nvmeWriteCount <= nvmeWriteCount + 1;
                endaction
            endseq
            action
                if (truncate(nvmeWriteCount) != (nvmeWriteLength >> 6)) begin
                    printColorTimed(RED, $format("ERROR: Wrong number of write beats received for transfer #%0d (0x%x vs. 0x%x)", nvmeWriteID, nvmeWriteCount, nvmeWriteLength >> 6));
                    $finish;
                end
            endaction
            // send response
            action
                let pkg = AXI4_Stream_Pkg {
                    data: 0,
                    user: 0,
                    keep: unpack(-1),
                    dest: 0,
                    last: True
                };
                axiNvmeWrRsp.pkg.put(pkg);
            endaction
            printColorTimed(BLUE, $format("Handling of NVMe write transfer #%d completed", nvmeWriteID));
        endseq
    };
    FSM nvmeWriteHandlingFSM <- mkFSM(nvmeWriteHandlingStmt);

    Reg#(Bit#(4)) fillBufferID <- mkReg(0);
    Reg#(Bit#(30)) fillBufferAddr <- mkReg(0);
    Reg#(Bit#(30)) fillBufferLength <- mkReg(0);
    Reg#(Bit#(508)) fillBufferCount <- mkReg(0);
    Stmt fillBufferStmt = {
        seq
            fillBufferCount <= 0;
            while(truncate(fillBufferCount) < fillBufferLength) seq
                action
                    let req = BRAMRequestBE {
                        writeen: unpack(-1),
                        responseOnWrite: False,
                        address: fillBufferAddr,
                        datain: {fillBufferID, fillBufferCount}
                    };
                    bram.portB.request.put(req);
                    fillBufferAddr <= fillBufferAddr + 1;
                    fillBufferCount <= fillBufferCount + 1;
                endaction
            endseq
        endseq
    };
    FSM fillBufferFSM <- mkFSM(fillBufferStmt);

    Reg#(Bit#(4)) checkBufferID <- mkReg(0);
    Reg#(Bit#(30)) checkBufferAddr <- mkReg(0);
    Reg#(Bit#(30)) checkBufferLength <- mkReg(0);
    Reg#(Bit#(30)) checkBufferCountReq <- mkReg(0);
    Reg#(Bit#(508)) checkBufferCountRsp <- mkReg(0);
    Stmt checkBufferStmt = {
        par
            seq
                checkBufferCountReq <= 0;
                while (checkBufferCountReq < checkBufferLength) seq
                    action
                        let req = BRAMRequestBE {
                            writeen: 0,
                            responseOnWrite: False,
                            address: checkBufferAddr,
                            datain: 0
                        };
                        bram.portB.request.put(req);
                        checkBufferCountReq <= checkBufferCountReq + 1;
                        checkBufferAddr <= checkBufferAddr + 1;
                    endaction
                endseq
            endseq
            seq
                checkBufferCountRsp <= 0;
                while (truncate(checkBufferCountRsp) < checkBufferLength) seq
                    action
                        let rsp <- bram.portB.response.get();
                        if (rsp[511:508] != checkBufferID) begin
                            printColorTimed(RED, $format("ERROR: Wrong ID in write data (#%0d vs. #%0d)", rsp[511:508], checkBufferID));
                            $finish;
                        end
                        if (rsp[507:0] != checkBufferCountRsp) begin
                            printColorTimed(RED, $format("ERROR: Wrong count in write data (0x%x vs. 0x%x)", rsp[511:508], checkBufferCountRsp));
                            $finish;
                        end
                        checkBufferCountRsp <= checkBufferCountRsp + 1;
                    endaction
                endseq
            endseq
        endpar
    };
    FSM checkBufferFSM <- mkFSM(checkBufferStmt);

    Vector#(7, NVMeCmdExt) cmdVector;
    cmdVector[0] = NVMeCmdExt {
        ddrAddr:  'h0,
        nvmeAddr: 'h000ac10000,
        nrPages:  'd38144,
        rw: 1
    };
    cmdVector[1] = NVMeCmdExt {
        ddrAddr:  'h9500000,
        nvmeAddr: 'h010b100000,
        nrPages:  'd12310,
        rw: 0
    };
    cmdVector[2] = NVMeCmdExt {
        ddrAddr:  'hc516000,
        nvmeAddr: 'h01fac00000,
        nrPages:  'd512,
        rw: 0
    };
    cmdVector[3] = NVMeCmdExt {
        ddrAddr:  'hc7106000,
        nvmeAddr: 'h01e00b0000,
        nrPages:  'd423,
        rw: 0
    };
    cmdVector[4] = NVMeCmdExt {
        ddrAddr:  'hc8bd000,
        nvmeAddr: 'h001f200000,
        nrPages:  'd189,
        rw: 1
    };
    cmdVector[5] = NVMeCmdExt {
        ddrAddr:  'hc97a000,
        nvmeAddr: 'h0170000000,
        nrPages:  'd28,
        rw: 0
    };
    cmdVector[6] = NVMeCmdExt {
        ddrAddr:  'hc996000,
        nvmeAddr: 'h00290ac000,
        nrPages:  'd37,
        rw: 1
    };
    Bit#(64) cmdBaseAddr = 'hc9bbb000;
    Stmt prepareCommandsStmt = {
        seq
            action
                let req = BRAMRequestBE {
                    writeen: unpack(-1),
                    responseOnWrite: False,
                    address: truncate(cmdBaseAddr >> 6),
                    datain: {pack(cmdVector[1]), pack(cmdVector[0])}
                };
                bram.portB.request.put(req);
            endaction
            action
                let req = BRAMRequestBE {
                    writeen: unpack(-1),
                    responseOnWrite: False,
                    address: truncate(cmdBaseAddr >> 6) + 1,
                    datain: {pack(cmdVector[3]), pack(cmdVector[2])}
                };
                bram.portB.request.put(req);
            endaction
            action
                let req = BRAMRequestBE {
                    writeen: unpack(-1),
                    responseOnWrite: False,
                    address: truncate(cmdBaseAddr >> 6) + 2,
                    datain: {pack(cmdVector[5]), pack(cmdVector[4])}
                };
                bram.portB.request.put(req);
            endaction
            action
                let req = BRAMRequestBE {
                    writeen: unpack(-1),
                    responseOnWrite: False,
                    address: truncate(cmdBaseAddr >> 6) + 3,
                    datain: {0, pack(cmdVector[6])}
                };
                bram.portB.request.put(req);
            endaction
        endseq
    };
    FSM prepareCommandsFSM <- mkFSM(prepareCommandsStmt);

    Reg#(UInt#(32)) i <- mkReg(0);
    Reg#(UInt#(32)) j <- mkReg(0);
    Reg#(UInt#(32)) k <- mkReg(0);
    Stmt mainStmt = {
        seq
            printColorTimed(BLUE, $format("Prepare buffer for write transfers"));
            for (i <= 0; i < 7; i <= i + 1) seq
                if (cmdVector[i].rw == 1) seq
                    fillBufferID <= truncate(pack(i));
                    fillBufferAddr <= truncate(cmdVector[i].ddrAddr >> 6);
                    fillBufferLength <= truncate(cmdVector[i].nrPages * 4096 / 64);
                    fillBufferFSM.start();
                    await(fillBufferFSM.done());
                endseq
            endseq

            printColorTimed(BLUE, $format("Prepare commands"));
            prepareCommandsFSM.start();
            await(prepareCommandsFSM.done());

            printColorTimed(BLUE, $format("Start DUT"));
            par
                // handle NVMe read transfers
                seq
                    for (i <= 0; i < 7; i <= i + 1) seq
                        if (cmdVector[i].rw == 0) seq
                            nvmeReadID <= truncate(pack(i));
                            nvmeReadAddress <= cmdVector[i].nvmeAddr;
                            nvmeReadLength <= cmdVector[i].nrPages * 4096;
                            nvmeReadHandlingFSM.start();
                            await(nvmeReadHandlingFSM.done());
                        endseq
                    endseq
                endseq
                // handle NVMe write transfers
                seq
                    for (j <= 0; j < 7; j <= j + 1) seq
                        if (cmdVector[j].rw == 1) seq
                            nvmeWriteID <= truncate(pack(j));
                            nvmeWriteAddress <= cmdVector[j].nvmeAddr;
                            nvmeWriteLength <= cmdVector[j].nrPages * 4096;
                            nvmeWriteHandlingFSM.start();
                            await(nvmeWriteHandlingFSM.done());
                        endseq
                    endseq
                endseq
                // DUT communication
                seq
                    axi4_lite_write(axiCtrlWr, 'h20, cmdBaseAddr);
                    axi4_lite_write(axiCtrlWr, 'h30, 7);
                    axi4_lite_write(axiCtrlWr, 'h00, 1);
                    for (k <= 0; k < 3; k <= k + 1) action
                        let r <- axi4_lite_write_response(axiCtrlWr);
                    endaction
                    await(dut.intr());
                endseq
            endpar

            printColorTimed(BLUE, $format("Check results in buffers of read transfers"));
            for (i <= 0; i < 7; i <= i + 1) seq
                if (cmdVector[i].rw == 0) seq
                    checkBufferID <= truncate(pack(i));
                    checkBufferAddr <= truncate(cmdVector[i].ddrAddr >> 6);
                    checkBufferLength <= truncate(cmdVector[i].nrPages * 4096 / 64);
                    checkBufferFSM.start();
                    await(checkBufferFSM.done());
                endseq
            endseq
        endseq
    };
    FSM mainFSM <- mkFSM(mainStmt);

    method Action go();
        mainFSM.start();
    endmethod

    method Bool done();
        return mainFSM.done();
    endmethod
endmodule

endpackage
