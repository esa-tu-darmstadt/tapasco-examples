package TestsMainTest;

`define PRINT_STREAM 300

import Vector::*;
import StmtFSM::*;
import Connectable::*;
import GetPut::*;

import BlueAXI::*;
import BlueLib::*;
import TestHelper::*;
import Defines::*;
import WeightStreamer::*;

(* synthesize *)
module [Module] mkTestsMainTest(TestHelper::TestHandler);
	AXI4_Lite_Master_Rd#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) axiCtrlRd <- mkAXI4_Lite_Master_Rd(2);
	AXI4_Lite_Master_Wr#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) axiCtrlWr <- mkAXI4_Lite_Master_Wr(2);
	AXI4_Lite_Master_Rd#(MEM_AXI_ADDR_WIDTH, CTRL_DATA_WIDTH) axiBramRd <- mkAXI4_Lite_Master_Rd(2);
	AXI4_Lite_Master_Wr#(MEM_AXI_ADDR_WIDTH, CTRL_DATA_WIDTH) axiBramWr <- mkAXI4_Lite_Master_Wr(2);
	Vector#(NUM_STREAMS, AXI4_Stream_Rd#(ST_DATA_WIDTH, ST_USER_WIDTH)) axiStRx <- replicateM(mkAXI4_Stream_Rd(2));
	WeightStreamer dut <- mkWeightStreamer();

	mkConnection(axiCtrlRd.fab, dut.s_ctrl_rd);
	mkConnection(axiCtrlWr.fab, dut.s_ctrl_wr);
	mkConnection(axiBramRd.fab, dut.s_bram_rd);
	mkConnection(axiBramWr.fab, dut.s_bram_wr);
	for (Integer i = 0; i < valueOf(NUM_STREAMS); i = i + 1) begin
		mkConnection(dut.st_fabs[i], axiStRx[i].fab);
	end

	rule discardCtrlRsp;
		let r <- axi4_lite_write_response(axiCtrlWr);
	endrule

	rule discardBramRsp;
		let r <- axi4_lite_write_response(axiBramWr);
	endrule

	Reg#(Bool) intrDetected <- mkReg(False);
	rule catchIntr if (dut.intr());
		intrDetected <= True;
	endrule

	Reg#(Bool) printStream <- mkReg(False);
	Vector#(NUM_STREAMS, Reg#(UInt#(32))) weightCnts <- replicateM(mkReg(0));
	for (Integer i = 0; i < valueOf(NUM_STREAMS); i = i + 1) begin
		rule checkWeights;
			let p <- axiStRx[i].pkg.get();
			Vector#(4, UInt#(32)) v = unpack(p.data);
			UInt#(32) baseVal = 0;
			if (i < numEngines[0])
				baseVal = (weightCnts[i] % fromInteger(bramSizePerEngine[0])
						+ fromInteger(i * bramSizePerEngine[0])) * 4;
			else if (i < numEngines[1])
				baseVal = (weightCnts[i] % fromInteger(bramSizePerEngine[1])
						+ fromInteger((i - numEngines[0]) * bramSizePerEngine[1] + valueOf(MAX_BRAM_SIZE_TOTAL))) * 4;
			else if (i < numEngines[2])
				baseVal = (weightCnts[i] % fromInteger(bramSizePerEngine[2])
						+ fromInteger((i - numEngines[0] - numEngines[1]) * bramSizePerEngine[2] + 2 *  valueOf(MAX_BRAM_SIZE_TOTAL))) * 4;
//			else
//				baseVal = (weightCnts[i] % fromInteger(bramSizePerEngine[3])
//						+ fromInteger((i - numEngines[0] - numEngines[1] - numEngines[2]) * bramSizePerEngine[3] + valueOf(MAX_BRAM_SIZE_TOTAL))) * 4;

			baseVal = 0;
			Integer cnt = 0;
			for (Integer k = 0; k < valueOf(NUM_LAYERS); k = k + 1) begin
				if (i >= cnt && i < cnt + numEngines[k]) begin
					baseVal = baseVal + (weightCnts[i] % fromInteger(bramSizePerEngine[k]));
				end
				cnt = cnt + numEngines[k];
			end
			baseVal = baseVal * 4;
			baseVal = baseVal + fromInteger(i * valueOf(MAX_BRAM_SIZE_PER_ENGINE) * 4);
			for (Integer k = 0; k < 3; k = k + 1) begin
				if (v[k] != baseVal + fromInteger(k)) begin
					printColorTimed(RED, $format("ERROR: Wrong value detected: Stream #%3d, Packet #%5d, Idx #%1d, Exp %4d, Act %4d",
							i, weightCnts[i], k, baseVal + fromInteger(k), v[k]));
					$finish;
				end
			end

			weightCnts[i] <= weightCnts[i] + 1;
			if (i == `PRINT_STREAM && printStream) begin
				printColorTimed(YELLOW, $format("#%5d: ", weightCnts[i]) + fshow(p));
			end
		endrule
	end

	Reg#(UInt#(32)) i <- mkReg(0);
	Stmt test0 = {
		seq
			printColorTimed(BLUE, $format("Start testcase 0"));
			printColorTimed(BLUE, $format("Load weights into BRAMs"));

			// FIXME change if layer configuration changes
			for (i <= 0; i < fromInteger(valueOf(NUM_STREAMS) * valueof(MAX_BRAM_SIZE_PER_ENGINE) * 4); i <= i + 2) seq
				action
					Bit#(CTRL_DATA_WIDTH) d = {pack(i + 1), pack(i)};
					Bit#(MEM_AXI_ADDR_WIDTH) a = pack(truncate(i * 4));
					axi4_lite_write(axiBramWr, a, d);
				endaction
			endseq

			printColorTimed(BLUE, $format("Launch module"));
			axi4_lite_write(axiCtrlWr, 0, 1);
			printStream <= True;
			delay(4000);
			printStream <= False;
			printColorTimed(BLUE, $format("Check whether all streams are active"));
			for (i <= 0; i < fromInteger(valueOf(NUM_STREAMS)); i <= i + 1) seq
				action
					if (weightCnts[i] == 0) begin
						printColorTimed(RED, $format("ERROR: Stream %3d not active", i));
						$finish;
					end
				endaction
			endseq
			printColorTimed(BLUE, $format("Check whether interrupt was sent"));
			action
				if (!intrDetected) begin
					printColorTimed(RED, $format("ERROR: No interrupt detected"));
					$finish;
				end
			endaction
			printColorTimed(BLUE, $format("Finished testcase 0"));
		endseq
	};
	FSM fsm0 <- mkFSM(test0);

	Stmt s = {
		seq
			printColorTimed(BLUE, $format("----------------------------------------------"));
			fsm0.start();
			await(fsm0.done());
			printColorTimed(BLUE, $format("----------------------------------------------"));
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
