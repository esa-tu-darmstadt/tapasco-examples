package TestsMainTest;

//`define PRINT_AI_DATA
//`define PRINT_AI_DATA_QUEUE_0
//`define PRINT_DMA_DATA
`define RUN_TESTCASE_0
`define RUN_TESTCASE_1
`define RUN_TESTCASE_2
`define RUN_TESTCASE_3
//`define SIM_BACK_PRESSURE

import Vector::*;
import Connectable::*;
import StmtFSM::*;
import FIFO::*;
import GetPut::*;

import BlueAXI::*;
import BlueLib::*;
import TestHelper::*;
import DataStreamer::*;

(* synthesize *)
module [Module] mkTestsMainTest(TestHelper::TestHandler);
	AXI4_Lite_Master_Rd#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) axiMasterRd <- mkAXI4_Lite_Master_Rd(2);
	AXI4_Lite_Master_Wr#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) axiMasterWr <- mkAXI4_Lite_Master_Wr(2);
	AXI4_Stream_Wr#(DMA_DATA_WIDTH, DMA_USER_WIDTH) h2cTx <- mkAXI4_Stream_Wr(2);
	AXI4_Stream_Rd#(DMA_DATA_WIDTH, DMA_USER_WIDTH) c2hRx <- mkAXI4_Stream_Rd(2);
	Vector#(4, AXI4_Stream_Rd#(ST_DATA_WIDTH, ST_USER_WIDTH)) axiStRx <- replicateM(mkAXI4_Stream_Rd(2));
	AXI4_Stream_Wr#(ST_DATA_WIDTH, ST_USER_WIDTH) axiStTx <- mkAXI4_Stream_Wr(2);

	DataStreamer dut <- mkDataStreamer();

	mkConnection(axiMasterRd.fab, dut.s_rd);
	mkConnection(axiMasterWr.fab, dut.s_wr);
	mkConnection(h2cTx.fab, dut.h2c_fab);
	mkConnection(dut.c2h_fab, c2hRx.fab);
	for (Integer i = 0; i < 4; i = i + 1) begin
		mkConnection(dut.feature_st_fabs[i], axiStRx[i].fab);
	end
	mkConnection(axiStTx.fab, dut.result_st_fab);

	Vector#(4, FIFO#(Bit#(0))) tokenFifos <- replicateM(mkSizedFIFO(16));
	Vector#(4, Reg#(UInt#(32))) streamInCnt <- replicateM(mkReg(0));
	for (Integer i = 0; i < 4; i = i + 1) begin
		Reg#(UInt#(4)) consumeDataCnt <- mkReg(0);
		rule consumeData;
			let p <- axiStRx[i].pkg.get();
			if (consumeDataCnt == 15) begin
				tokenFifos[i].enq(0);
				consumeDataCnt <= 0;
			end
			else begin
				consumeDataCnt <= consumeDataCnt + 1;
			end
			streamInCnt[i] <= streamInCnt[i] + 1;
`ifdef PRINT_AI_DATA
			printColorTimed(YELLOW, $format("Queue #%0d: ", i) + fshow(p) + $format(", Pkt #%3d", streamInCnt[i]));
`else `ifdef PRINT_AI_DATA_QUEUE_0
			if (i == 0)
				printColorTimed(YELLOW, $format("Queue #%0d: ", i) + fshow(p) + $format(", Pkt #%3d", streamInCnt[i]));
`endif
`endif
		endrule
	end

	Reg#(UInt#(32)) returnDataCnt <- mkReg(0);
	Reg#(UInt#(32)) returnDataWaitCnt <- mkReg(0);
	rule returnData;
`ifdef SIM_BACK_PRESSURE
		if (returnDataWaitCnt == 4096) begin
`endif
			for (Integer i = 0; i < 4; i = i + 1) begin
				tokenFifos[i].deq();
			end
			Vector#(4, UInt#(32)) vd = newVector();
			for (Integer i = 0; i < 4; i = i + 1) begin
				vd[i] = returnDataCnt * 4 + fromInteger(i);
			end
			let p = AXI4_Stream_Pkg {
				data: pack(vd),
				keep: unpack(-1),
				last: False,
				user: 0,
				dest: 0
			};
			axiStTx.pkg.put(p);
			returnDataCnt <= returnDataCnt + 1;
`ifdef SIM_BACK_PRESSURE
			returnDataWaitCnt <= 0;
		end
		else begin
			returnDataWaitCnt <= returnDataWaitCnt + 1;
		end
`endif
	endrule

	Reg#(UInt#(32)) c2hCnt <- mkReg(0);
	rule printDMAC2H;
		let p <- c2hRx.pkg.get();
		c2hCnt <= c2hCnt + 1;
`ifdef PRINT_DMA_DATA
		printColorTimed(GREEN, fshow(p));
`endif
	endrule

	Reg#(Bool) lastIrq <- mkReg(False);
	Reg#(UInt#(32)) irqCnt <- mkReg(0);
	rule countIntr;
		lastIrq <= dut.intr();
		if (!lastIrq && dut.intr())
			irqCnt <= irqCnt + 1;
	endrule

	rule discardWriteResponses;
		let r <- axi4_lite_write_response(axiMasterWr);
	endrule

	Reg#(Bit#(32)) sendCnt <- mkReg(0);
	function Action sendH2CBeat(Bool last);
		action
			Vector#(16, Bit#(32)) vd = newVector;
			for (Integer i = 0; i < 16; i = i + 1) begin
				vd[i] = sendCnt * 16 + fromInteger(i);
			end
			let p = AXI4_Stream_Pkg {
				data: pack(vd),
				user: 0,
				keep: unpack(-1),
				dest: 0,
				last: last
			};
			h2cTx.pkg.put(p);
			sendCnt <= sendCnt + 1;
		endaction
	endfunction

	Reg#(UInt#(32)) ir <- mkReg(0);
	Stmt stmt0 = {
		seq
			printColorTimed(BLUE, $format("Test batch size of 64"));
			returnDataCnt <= 0;
			c2hCnt <= 0;
			irqCnt <= 0;
			for (ir <= 0; ir < 4; ir <= ir + 1) seq
				streamInCnt[ir] <= 0;
			endseq
			axi4_lite_read(axiMasterRd, 'h10);
			action
				let r <- axi4_lite_read_response(axiMasterRd);
				if (r != 0) begin
					printColorTimed(RED, $format("ERROR: Cycle count not initially zero"));
					$finish;
				end
			endaction
			printColorTimed(BLUE, $format("Write config registers"));
			axi4_lite_write(axiMasterWr, 'h20, 64);
			axi4_lite_write(axiMasterWr, 'h00, 1);
			for (ir <= 0; ir < 64 * 4 - 1; ir <= ir + 1) seq
				sendH2CBeat(False);
			endseq
			sendH2CBeat(True);
			action
				if (irqCnt != 0) begin
					printColorTimed(RED, $format("ERROR: Detected IRQ too early"));
					$finish;
				end
			endaction
			printColorTimed(BLUE, $format("Wait for interrupt"));
			await(irqCnt != 0);
			printColorTimed(BLUE, $format("Interrupt detected"));
			for (ir <= 0; ir < 4; ir <= ir + 1) seq
				action
					UInt#(32) exp = 64 * 64 / 4 / 4; // num_batches * batch_size / streams / f32 per 128 bit
					if (streamInCnt[ir] != exp) begin
						printColorTimed(RED, $format("ERROR: Wrong number of stream beats received (%0d (act.) vs. %0d (act.))", exp, streamInCnt[ir]));
						$finish;
					end
				endaction
			endseq
			action
				if (c2hCnt != 4) begin
					printColorTimed(RED, $format("ERROR: Wrong number of C2H beats received (%0d (act.) vs. 4 (exp.))", c2hCnt));
					$finish;
				end
			endaction
			axi4_lite_read(axiMasterRd, 'h10);
			action
				let r <- axi4_lite_read_response(axiMasterRd);
				if (r == 0) begin
					printColorTimed(RED, $format("ERROR: Cycle count still zero"));
					$finish;
				end
				printColorTimed(GREEN, $format("Cycle count of first test case: 0x%x", r));
			endaction
		endseq
	};
	FSM fsm0 <- mkFSM(stmt0);

	Stmt stmt1 = {
		seq
			printColorTimed(BLUE, $format("Test batch size of 1024"));
			returnDataCnt <= 0;
			c2hCnt <= 0;
			irqCnt <= 0;
			printColorTimed(BLUE, $format("Write config registers"));
			axi4_lite_write(axiMasterWr, 'h20, 1024);
			axi4_lite_write(axiMasterWr, 'h00, 1);
			delay(10);
			axi4_lite_read(axiMasterRd, 'h10);
			action
				let r <- axi4_lite_read_response(axiMasterRd);
				if (r >= 20) begin
					printColorTimed(RED, $format("ERROR: Cycle count has not been reset"));
					$finish;
				end
			endaction
			for (ir <= 0; ir < 1024 * 4 - 1; ir <= ir + 1) seq
				sendH2CBeat(False);
			endseq
			sendH2CBeat(True);
			action
				if (irqCnt != 0) begin
					printColorTimed(RED, $format("ERROR: Detected IRQ too early"));
					$finish;
				end
			endaction
			printColorTimed(BLUE, $format("Wait for interrupt"));
			await(irqCnt != 0);
			printColorTimed(BLUE, $format("Interrupt detected"));
			action
				if (c2hCnt != 64) begin
					printColorTimed(RED, $format("ERROR: Wrong number of C2H beats received (%0d (act.) vs. 64 (exp.))", c2hCnt));
					$finish;
				end
			endaction
			axi4_lite_read(axiMasterRd, 'h10);
			action
				let r <- axi4_lite_read_response(axiMasterRd);
				if (r == 0) begin
					printColorTimed(RED, $format("ERROR: Cycle count still zero"));
					$finish;
				end
				printColorTimed(GREEN, $format("Cycle count of second test case: 0x%x", r));
			endaction
		endseq
	};
	FSM fsm1 <- mkFSM(stmt1);

	Stmt stmt2 = {
		seq
			printColorTimed(BLUE, $format("Test batch size of 16384"));
			returnDataCnt <= 0;
			c2hCnt <= 0;
			irqCnt <= 0;
			printColorTimed(BLUE, $format("Write config registers"));
			axi4_lite_write(axiMasterWr, 'h20, 16384);
			axi4_lite_write(axiMasterWr, 'h00, 1);
			for (ir <= 0; ir < 16384 * 4 - 1; ir <= ir + 1) seq
				sendH2CBeat(False);
			endseq
			sendH2CBeat(True);
			action
				if (irqCnt != 0) begin
					printColorTimed(RED, $format("ERROR: Detected IRQ too early"));
					$finish;
				end
			endaction
			printColorTimed(BLUE, $format("Wait for interrupt"));
			await(irqCnt != 0);
			printColorTimed(BLUE, $format("Interrupt detected"));
			action
				if (c2hCnt != 1024) begin
					printColorTimed(RED, $format("ERROR: Wrong number of C2H beats received (%0d (act.) vs. 1024 (exp.))", c2hCnt));
					$finish;
				end
			endaction
		endseq
	};
	FSM fsm2 <- mkFSM(stmt2);

	Stmt stmt3 = {
		seq
			printColorTimed(BLUE, $format("Test batch size of 1048576"));
			returnDataCnt <= 0;
			c2hCnt <= 0;
			irqCnt <= 0;
			printColorTimed(BLUE, $format("Write config registers"));
			axi4_lite_write(axiMasterWr, 'h20, 1048576);
			axi4_lite_write(axiMasterWr, 'h00, 1);
			for (ir <= 0; ir < 1048576 * 4 - 1; ir <= ir + 1) seq
				sendH2CBeat(False);
			endseq
			sendH2CBeat(True);
			action
				if (irqCnt != 0) begin
					printColorTimed(RED, $format("ERROR: Detected IRQ too early"));
					$finish;
				end
			endaction
			printColorTimed(BLUE, $format("Wait for interrupt"));
			await(irqCnt != 0);
			printColorTimed(BLUE, $format("Interrupt detected"));
			action
				if (c2hCnt != 65536) begin
					printColorTimed(RED, $format("ERROR: Wrong number of C2H beats received (%0d (act.) vs. 65536 (exp.))", c2hCnt));
					$finish;
				end
			endaction
		endseq
	};
	FSM fsm3 <- mkFSM(stmt3);

	Stmt s = {
		seq
			printColorTimed(BLUE, $format("Start testbench"));
`ifdef RUN_TESTCASE_0
			printColorTimed(BLUE, $format("-----------------------------------------------"));
			fsm0.start();
			await(fsm0.done());
			delay(100);
			printColorTimed(BLUE, $format("-----------------------------------------------"));
`endif
`ifdef RUN_TESTCASE_1
			printColorTimed(BLUE, $format("-----------------------------------------------"));
			fsm1.start();
			await(fsm1.done());
			delay(100);
			printColorTimed(BLUE, $format("-----------------------------------------------"));
`endif
`ifdef RUN_TESTCASE_2
			printColorTimed(BLUE, $format("-----------------------------------------------"));
			fsm2.start();
			await(fsm2.done());
			delay(100);
			printColorTimed(BLUE, $format("-----------------------------------------------"));
`endif
`ifdef RUN_TESTCASE_3
			printColorTimed(BLUE, $format("-----------------------------------------------"));
			fsm3.start();
			await(fsm3.done());
			delay(100);
			printColorTimed(BLUE, $format("-----------------------------------------------"));
`endif
			printColorTimed(BLUE, $format("Finished all test cases"));
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
