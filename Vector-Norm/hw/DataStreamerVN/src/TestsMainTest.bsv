package TestsMainTest;
    import StmtFSM :: *;
    import TestHelper :: *;
    import BlueAXI :: *;
    import BlueLib :: *;
    import Connectable :: *;
    import DataStreamerVN :: *;

    import FIFO::*;
    import GetPut::*;
    import Vector::*;

    (* synthesize *)
    module [Module] mkTestsMainTest(TestHelper::TestHandler);

        DataStreamerVN dut <- mkDataStreamerVN();
        AXI4_Stream_Rd#(AXIS_AIE_DATA_WIDTH, 0) s_axis_aie_x_inst <- mkAXI4_Stream_Rd(2);
        AXI4_Stream_Rd#(AXIS_AIE_DATA_WIDTH, 0) s_axis_aie_y_inst <- mkAXI4_Stream_Rd(2);
        AXI4_Stream_Wr#(AXIS_AIE_DATA_WIDTH, 0) m_axis_aie_inst <- mkAXI4_Stream_Wr(2);
        AXI4_Stream_Rd#(AXIS_DMA_DATA_WIDTH, 0) s_axis_dma_inst <- mkAXI4_Stream_Rd(2);
        AXI4_Stream_Wr#(AXIS_DMA_DATA_WIDTH, 0) m_axis_dma_inst <- mkAXI4_Stream_Wr(2);
        AXI4_Lite_Master_Wr#(AXI_SLAVE_ADDR_WIDTH, AXI_SLAVE_DATA_WIDTH) m_axi_lite_wr_inst <- mkAXI4_Lite_Master_Wr(16);
        AXI4_Lite_Master_Rd#(AXI_SLAVE_ADDR_WIDTH, AXI_SLAVE_DATA_WIDTH) m_axi_lite_rd_inst <- mkAXI4_Lite_Master_Rd(16);

        mkConnection(dut.m_axis_aie_x, s_axis_aie_x_inst.fab);
        mkConnection(dut.m_axis_aie_y, s_axis_aie_y_inst.fab);
        mkConnection(m_axis_aie_inst.fab, dut.s_axis_aie);
        mkConnection(dut.m_axis_dma, s_axis_dma_inst.fab);
        mkConnection(m_axis_dma_inst.fab, dut.s_axis_dma);
        mkConnection(m_axi_lite_rd_inst.fab, dut.s_lite_rd);
        mkConnection(m_axi_lite_wr_inst.fab, dut.s_lite_wr);

        Vector#(2, FIFO#(Bit#(0))) tokenFifos <- replicateM(mkSizedFIFO(16));
        rule getXBeat;
            let p <- s_axis_aie_x_inst.pkg.get();
            tokenFifos[0].enq(0);
        endrule

        rule getYBeat;
            let p <- s_axis_aie_y_inst.pkg.get();
            tokenFifos[1].enq(0);
        endrule

        Reg#(UInt#(128)) resultCount <- mkReg(0);
        rule sendResultBeat;
            tokenFifos[0].deq();
            tokenFifos[1].deq();
            let p = AXI4_Stream_Pkg {
                data: pack(resultCount),
                user: 0,
                keep: unpack(-1),
                dest: 0,
                last: False
            };
            m_axis_aie_inst.pkg.put(p);
            resultCount <= resultCount + 1;
        endrule

        Reg#(UInt#(128)) receiveCount <- mkReg(0);
        rule receivDMABeats;
            let p <- s_axis_dma_inst.pkg.get();
            Vector#(4, UInt#(128)) refVal = newVector;
            for (Integer i = 0; i < 4; i = i + 1) begin
                refVal[i] = receiveCount * 4 + fromInteger(i);
            end
            if (p.data != pack(refVal)) begin
                printColorTimed(RED, $format("ERROR: Wrong DMA packet received"));
            end
            receiveCount <= receiveCount + 1;
        endrule

        Reg#(UInt#(128)) i0 <- mkReg(0);
        Reg#(UInt#(128)) i1 <- mkReg(0);
        Reg#(UInt#(128)) i2 <- mkReg(0);
        Stmt s = {
            seq
                printColorTimed(BLUE, $format("Start testbench."));
                printColorTimed(BLUE, $format("First testcase"));
                axi4_lite_write(m_axi_lite_wr_inst, 'h20, 16384);
                axi4_lite_write(m_axi_lite_wr_inst, 'h00, 1);
                par
                    seq
                        await(dut.interrupt());
                    endseq
                    seq
                        for (i0 <= 0; i0 < 2048; i0 <= i0 + 1) action
                            let p = AXI4_Stream_Pkg {
                                data: extend(pack(i0)),
                                user: 0,
                                keep: unpack(-1),
                                dest: 0,
                                last: False
                            };
                            m_axis_dma_inst.pkg.put(p);
                        endaction
                    endseq
                endpar
                delay(100);
                action
                    if (resultCount != 4096) begin
                        printColorTimed(RED, $format("Wrong number of AIE beats received"));
                    end
                    if (receiveCount != 1024) begin
                        printColorTimed(RED, $format("Wrong number of DMA beats received"));
                    end
                endaction

                printColorTimed(BLUE, $format("Second testcase"));
                resultCount <= 0;
                receiveCount <= 0;
                axi4_lite_write(m_axi_lite_wr_inst, 'h20, 2048);
                axi4_lite_write(m_axi_lite_wr_inst, 'h00, 1);
                par
                    seq
                        await(dut.interrupt());
                    endseq
                    seq
                        for (i0 <= 0; i0 < 256; i0 <= i0 + 1) action
                            let p = AXI4_Stream_Pkg {
                                data: extend(pack(i0)),
                                user: 0,
                                keep: unpack(-1),
                                dest: 0,
                                last: False
                            };
                            m_axis_dma_inst.pkg.put(p);
                        endaction
                    endseq
                endpar
                delay(100);
                action
                    if (resultCount != 512) begin
                        printColorTimed(RED, $format("Wrong number of AIE beats received (%d vs. 512)", resultCount));
                    end
                    if (receiveCount != 128) begin
                        printColorTimed(RED, $format("Wrong number of DMA beats received (%d vs. 128)", receiveCount));
                    end
                endaction
                printColorTimed(BLUE, $format("Finished testbench."));
            endseq
        };
        FSM testFSM <- mkFSM(s);

        rule dropWrSlaveResp;
            let r <- axi4_lite_write_response(m_axi_lite_wr_inst);
        endrule

        method Action go();
            testFSM.start();
        endmethod

        method Bool done();
            return testFSM.done();
        endmethod
    endmodule

endpackage
