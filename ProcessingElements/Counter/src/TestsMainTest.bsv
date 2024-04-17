package TestsMainTest;
    import StmtFSM :: *;
    import TestHelper :: *;
    import CounterPE :: *;

    import BlueAXI :: *;
    import Connectable :: *;

    (* synthesize *)
    module [Module] mkTestsMainTest(TestHandler);

        CounterPE dut <- mkCounter();

        AXI4_Lite_Master_Wr#(CONFIG_ADDR_WIDTH, CONFIG_DATA_WIDTH) writeMaster <- mkAXI4_Lite_Master_Wr(16);
        AXI4_Lite_Master_Rd#(CONFIG_ADDR_WIDTH, CONFIG_DATA_WIDTH) readMaster <- mkAXI4_Lite_Master_Rd(16);

        mkConnection(writeMaster.fab, dut.s_wr);
        mkConnection(readMaster.fab, dut.s_rd);

        Stmt s = {
            seq
                // start PE
                axi4_lite_write(writeMaster, 'h20, 0);
                action let r <- axi4_lite_write_response(writeMaster); endaction
                axi4_lite_write(writeMaster, 'h0, 1);
                $display("[%07d] Counter started for %07d cycles", $time, 0);
                // wait for interrupt
                await(dut.interrupt);
                $display("[%07d] Counter finished", $time);
                action let r <- axi4_lite_write_response(writeMaster); endaction

                // start PE
                axi4_lite_write(writeMaster, 'h20, 234);
                action let r <- axi4_lite_write_response(writeMaster); endaction
                axi4_lite_write(writeMaster, 'h0, 1);
                $display("[%07d] Counter started for %07d cycles", $time, 234);
                // wait for interrupt
                await(dut.interrupt);
                $display("[%07d] Counter finished", $time);
                action let r <- axi4_lite_write_response(writeMaster); endaction

                // start PE
                axi4_lite_write(writeMaster, 'h20, 1);
                action let r <- axi4_lite_write_response(writeMaster); endaction
                axi4_lite_write(writeMaster, 'h0, 1);
                $display("[%07d] Counter started for %07d cycles", $time, 1);
                // wait for interrupt
                await(dut.interrupt);
                $display("[%07d] Counter finished", $time);
                action let r <- axi4_lite_write_response(writeMaster); endaction

                // start PE
                axi4_lite_write(writeMaster, 'h20, 12342);
                action let r <- axi4_lite_write_response(writeMaster); endaction
                axi4_lite_write(writeMaster, 'h0, 1);
                $display("[%07d] Counter started for %07d cycles", $time, 12342);
                // wait for interrupt
                await(dut.interrupt);
                $display("[%07d] Counter finished", $time);
                action let r <- axi4_lite_write_response(writeMaster); endaction
            endseq
        };
        FSM testFSM <- mkFSM(s);

        method Action go();
            testFSM.start();
        endmethod

        method Bool done();
            return testFSM.done();
        endmethod
    endmodule

endpackage
