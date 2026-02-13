package Testbench;
    import Vector :: *;
    import StmtFSM :: *;

    import TestHelper :: *;

    // Project Modules
    import `RUN_TEST :: *;

    typedef 1 TestAmount;

    (* synthesize *)
    module [Module] mkTestbench();
        Vector#(TestAmount, TestHandler) testVec;
        testVec[0] <- `TESTNAME ();

        Reg#(UInt#(32)) testCounter <- mkReg(0);
        Stmt s = {
            seq
                for(testCounter <= 0;
                    testCounter < fromInteger(valueOf(TestAmount));
                    testCounter <= testCounter + 1)
                seq
                    testVec[testCounter].go();
                    await(testVec[testCounter].done());
                endseq
            endseq
        };
        mkAutoFSM(s);
    endmodule

endpackage
