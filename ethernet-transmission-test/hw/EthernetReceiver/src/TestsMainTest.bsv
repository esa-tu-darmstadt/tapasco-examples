package TestsMainTest;

import StmtFSM::*;
import FIFO::*;
import FIFOF::*;
import GetPut::*;
import Connectable::*;

import BlueAXI::*;
import BlueLib::*;	
import TestHelper::*;
import EthernetReceiver::*;

typedef struct {
	Bit#(48) srcMac;
	Bit#(48) dstMac;
	Bit#(16) ethType;
	UInt#(9) len;
} EthernetFrame deriving (Bits, Eq, FShow);

(* synthesize *)
module [Module] mkTestsMainTest(TestHelper::TestHandler);
	AXI4_Lite_Master_Rd#(12, 64) axiMasterRd <- mkAXI4_Lite_Master_Rd(2);
	AXI4_Lite_Master_Wr#(12, 64) axiMasterWr <- mkAXI4_Lite_Master_Wr(2);
	AXI4_Slave_Rd#(32, 512, 1, 0) axiSlaveRd <- mkAXI4_Slave_Rd(2, 2);
	AXI4_Slave_Wr#(32, 512, 1, 0) axiSlaveWr <- mkAXI4_Slave_Wr(2, 2, 2);
	AXI4_Stream_Rd#(512, 0) axiRx <- mkAXI4_Stream_Rd(2);
	AXI4_Stream_Wr#(512, 0) axiTx <- mkAXI4_Stream_Wr(2);
	EthernetReceiver dut <- mkEthernetReceiver();
	mkConnection(axiMasterRd.fab, dut.s_ctrl_rd);
	mkConnection(axiMasterWr.fab, dut.s_ctrl_wr);
	mkConnection(dut.axi_rd_fab, axiSlaveRd.fab);
	mkConnection(dut.axi_wr_fab, axiSlaveWr.fab);
	mkConnection(dut.tx_fab, axiRx.fab);
	mkConnection(axiTx.fab, dut.rx_fab);


	Reg#(Bool) enableReceive <- mkReg(False);
	Reg#(Bool) activeWrite <- mkReg(False);
	Reg#(Bit#(512)) writeBeatCount <- mkReg(0);
	Reg#(Bit#(32)) writeAddr <- mkReg(0);
	Reg#(Bool) ignoreWrongData <- mkReg(False);
	rule receiveRequest if (enableReceive && !activeWrite);
		let r <- axiSlaveWr.request_addr.get();
		activeWrite <= True;
		writeAddr <= writeAddr + 'h1000;
		if (r.addr != writeAddr) begin
			printColorTimed(RED, $format("ERROR: Wrong write address"));
			$finish;
		end
	endrule

	rule receiveBeat if (enableReceive && activeWrite);
		let p <- axiSlaveWr.request_data.get();
		if (p.last) begin
			activeWrite <= False;
			axiSlaveWr.response.put(AXI4_Write_Rs {resp: OKAY, id: 0, user: 0});
		end
		writeBeatCount <= writeBeatCount + 1;
		if (!ignoreWrongData && p.data != writeBeatCount) begin
			printColorTimed(RED, $format("ERROR: Wrong data beat: %x vs. %x", p.data, writeBeatCount));
			$finish;
		end
	endrule

	FIFO#(EthernetFrame) frameQueue <- mkFIFO;
	FIFO#(Bit#(0)) doneFifo <- mkFIFO;
	Reg#(UInt#(9)) txCount <- mkReg(0);
	Reg#(UInt#(32)) totalBeatCount <- mkReg(0);
	rule sendHeader if (txCount == 0);
		let f = frameQueue.first();
		let e = Ethernet {
			payload: pack(extend(totalBeatCount)),
			ether_type: f.ethType,
			src_mac: f.srcMac,
			dst_mac: f.dstMac
		};
		axiTx.pkg.put(AXI4_Stream_Pkg {
			data: pack(e),
			keep: unpack(-1),
			last: False,
			user: 0,
			dest: 0
		});
		txCount <= 1;
		totalBeatCount <= totalBeatCount + 1;
	endrule

	rule sendPacket if (txCount > 0);
		let p;
		if (txCount == frameQueue.first().len) begin // last beat of frame
			p = AXI4_Stream_Pkg {
				data: 0,
				keep: unpack(-1),
				last: True,
				user: 0,
				dest: 0
			};
			frameQueue.deq();
			doneFifo.enq(0);
			txCount <= 0;
		end
		else begin
			p = AXI4_Stream_Pkg {
				data: pack(extend(totalBeatCount) << 112),
				keep: unpack(-1),
				last: False,
				user: 0,
				dest: 0
			};
			txCount <= txCount + 1;
			totalBeatCount <= totalBeatCount + 1;
		end
		axiTx.pkg.put(p);
	endrule

	rule discardWriteResp;
		let r <- axi4_lite_write_response(axiMasterWr);
	endrule

	function Action checkResult(Bit#(64) result, Bit#(32) beatCountRef, Bit#(12) wrongHeaderCountRef, Bit#(12) wrongFrameLenCountRef, Bool dropBeatErrorRef);
		action
			// printColorTimed(YELLOW, fshow(result));
			if (!dropBeatErrorRef && result[31:0] != beatCountRef) begin
				printColorTimed(RED, $format("ERROR: Beat count does not match reference (%x vs. %x)", result[31:0], beatCountRef));
				$finish;
			end
			if (result[43:32] != wrongHeaderCountRef) begin
				printColorTimed(RED, $format("ERROR: Wrong header count does not match reference"));
				$finish;
			end
			if (result[55:44] != wrongFrameLenCountRef) begin
				printColorTimed(RED, $format("ERROR: Wrong frame length count does not match reference"));
				$finish;
			end
			if (unpack(result[56]) != dropBeatErrorRef) begin
				printColorTimed(RED, $format("ERROR: Drop beat error flag does not match reference"));
				$finish;
			end
		endaction
	endfunction

	Reg#(UInt#(32)) ir <- mkReg(0);
	Reg#(UInt#(32)) jr <- mkReg(0);
	Stmt s = {
		seq
			printColorTimed(BLUE, $format("------------------------"));
			printColorTimed(BLUE, $format("Transmit 20 frames"));
			printColorTimed(BLUE, $format("------------------------"));
			writeAddr <= 'h20000;
			axi4_lite_write(axiMasterWr, 'h20, 'h20000);
			axi4_lite_write(axiMasterWr, 'h30, 'h100000);
			axi4_lite_write(axiMasterWr, 'h40, 'h2000);
			axi4_lite_write(axiMasterWr, 'h50, 'h112200334400);
			axi4_lite_write(axiMasterWr, 'h60, 'h550000660077);
			axi4_lite_write(axiMasterWr, 'h70, 'hAABB);
			axi4_lite_write(axiMasterWr, 'h00, 1);
			enableReceive <= True;
			par
				for (ir <= 0; ir < 20; ir <= ir + 1) action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660077,
						ethType: 'hAABB,
						len: 128 				// 8192 / 64
					};
					frameQueue.enq(f);
				endaction
				for (jr <= 0; jr < 20; jr <= jr + 1) action
					doneFifo.deq();
				endaction
			endpar
			await(dut.intr());
			axi4_lite_read(axiMasterRd, 'h10);
			action
				let r <- axi4_lite_read_response(axiMasterRd);
				checkResult(r, 20 * 'h2000 / 64, 0, 0, False);
			endaction

			printColorTimed(BLUE, $format("------------------------"));
			printColorTimed(BLUE, $format("Transmit 5 frames"));
			printColorTimed(BLUE, $format("------------------------"));
			writeAddr <= 'h10000;
			axi4_lite_write(axiMasterWr, 'h20, 'h10000);
			axi4_lite_write(axiMasterWr, 'h30, 'h1000);
			axi4_lite_write(axiMasterWr, 'h40, 'h2000);
			axi4_lite_write(axiMasterWr, 'h50, 'h112200334400);
			axi4_lite_write(axiMasterWr, 'h60, 'h550000660077);
			axi4_lite_write(axiMasterWr, 'h70, 'hAABB);
			axi4_lite_write(axiMasterWr, 'h00, 1);
			enableReceive <= True;
			par
				for (ir <= 0; ir < 5; ir <= ir + 1) action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660077,
						ethType: 'hAABB,
						len: 128 				// 8192 / 64
					};
					frameQueue.enq(f);
				endaction
				for (jr <= 0; jr < 5; jr <= jr + 1) action
					doneFifo.deq();
				endaction
			endpar
			await(dut.intr());
			axi4_lite_read(axiMasterRd, 'h10);
			action
				let r <- axi4_lite_read_response(axiMasterRd);
				checkResult(r, 5 * 'h2000 / 64, 0, 0, False);
			endaction

			printColorTimed(BLUE, $format("------------------------"));
			printColorTimed(BLUE, $format("Transmit frames with wrong headers"));
			printColorTimed(BLUE, $format("------------------------"));
			ignoreWrongData <= True;
			writeAddr <= 'h10000;
			axi4_lite_write(axiMasterWr, 'h20, 'h10000);
			axi4_lite_write(axiMasterWr, 'h30, 'h1000);
			axi4_lite_write(axiMasterWr, 'h40, 'h2000);
			axi4_lite_write(axiMasterWr, 'h50, 'h112200334400);
			axi4_lite_write(axiMasterWr, 'h60, 'h550000660077);
			axi4_lite_write(axiMasterWr, 'h70, 'hAABB);
			axi4_lite_write(axiMasterWr, 'h00, 1);
			enableReceive <= True;
			par
				action
					let f = EthernetFrame {
						srcMac: 'h112200334300, // wrong source MAC
						dstMac: 'h550000660077,
						ethType: 'hAABB,
						len: 128 				// 8192 / 64
					};
					frameQueue.enq(f);
				endaction
				action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660077,
						ethType: 'hAABB,
						len: 128 				// 8192 / 64
					};
					frameQueue.enq(f);
				endaction
				action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660177, // wrong destination MAC
						ethType: 'hAABB,
						len: 128 				// 8192 / 64
					};
					frameQueue.enq(f);
				endaction
				action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660077,
						ethType: 'hAABC,		// wrong ethernet type
						len: 128 				// 8192 / 64
					};
					frameQueue.enq(f);
				endaction
				action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660077,
						ethType: 'hAABB,
						len: 128 				// 8192 / 64
					};
					frameQueue.enq(f);
				endaction
				for (jr <= 0; jr < 5; jr <= jr + 1) action
					doneFifo.deq();
				endaction
			endpar
			await(dut.intr());
			axi4_lite_read(axiMasterRd, 'h10);
			action
				let r <- axi4_lite_read_response(axiMasterRd);
				checkResult(r, 2 * 'h2000 / 64, 3, 0, False);
			endaction

			printColorTimed(BLUE, $format("------------------------"));
			printColorTimed(BLUE, $format("Transmit frames with wrong length"));
			printColorTimed(BLUE, $format("------------------------"));
			writeAddr <= 'h10000;
			axi4_lite_write(axiMasterWr, 'h20, 'h10000);
			axi4_lite_write(axiMasterWr, 'h30, 'h1000);
			axi4_lite_write(axiMasterWr, 'h40, 'h2000);
			axi4_lite_write(axiMasterWr, 'h50, 'h112200334400);
			axi4_lite_write(axiMasterWr, 'h60, 'h550000660077);
			axi4_lite_write(axiMasterWr, 'h70, 'hAABB);
			axi4_lite_write(axiMasterWr, 'h00, 1);
			enableReceive <= True;
			par
				action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660077,
						ethType: 'hAABB,
						len: 128 				// 8192 / 64
					};
					frameQueue.enq(f);
				endaction
				action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660077,
						ethType: 'hAABB,
						len: 64 				// 4096 / 64
					};
					frameQueue.enq(f);
				endaction
				action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660077,
						ethType: 'hAABB,
						len: 24 				// 1536 / 64
					};
					frameQueue.enq(f);
				endaction
				action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660077,
						ethType: 'hAABB,
						len: 128 				// 8192 / 64
					};
					frameQueue.enq(f);
				endaction
				action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660077,
						ethType: 'hAABB,
						len: 32 				// 2048 / 64
					};
					frameQueue.enq(f);
				endaction
				for (jr <= 0; jr < 5; jr <= jr + 1) action
					doneFifo.deq();
				endaction
			endpar
			await(dut.intr());
			axi4_lite_read(axiMasterRd, 'h10);
			action
				let r <- axi4_lite_read_response(axiMasterRd);
				checkResult(r, 128 + 64 + 24 + 128 + 32, 0, 3, False);
			endaction

			printColorTimed(BLUE, $format("------------------------"));
			printColorTimed(BLUE, $format("Transmit 10 frames"));
			printColorTimed(BLUE, $format("------------------------"));
			ignoreWrongData <= False;
			writeBeatCount <= 0;
			totalBeatCount <= 0;
			writeAddr <= 'h40000;
			axi4_lite_write(axiMasterWr, 'h20, 'h40000);
			axi4_lite_write(axiMasterWr, 'h30, 'h100000);
			axi4_lite_write(axiMasterWr, 'h40, 'h2000);
			axi4_lite_write(axiMasterWr, 'h50, 'h112200334400);
			axi4_lite_write(axiMasterWr, 'h60, 'h550000660077);
			axi4_lite_write(axiMasterWr, 'h70, 'hAABB);
			axi4_lite_write(axiMasterWr, 'h00, 1);
			enableReceive <= True;
			par
				for (ir <= 0; ir < 10; ir <= ir + 1) action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660077,
						ethType: 'hAABB,
						len: 128 				// 8192 / 64
					};
					frameQueue.enq(f);
				endaction
				for (jr <= 0; jr < 10; jr <= jr + 1) action
					doneFifo.deq();
				endaction
			endpar
			await(dut.intr());
			axi4_lite_read(axiMasterRd, 'h10);
			action
				let r <- axi4_lite_read_response(axiMasterRd);
				checkResult(r, 10 * 'h2000 / 64, 0, 0, False);
			endaction

			printColorTimed(BLUE, $format("------------------------"));
			printColorTimed(BLUE, $format("Simulate back pressure"));
			printColorTimed(BLUE, $format("------------------------"));
			ignoreWrongData <= True;
			writeAddr <= 'h40000;
			axi4_lite_write(axiMasterWr, 'h20, 'h40000);
			axi4_lite_write(axiMasterWr, 'h30, 'h100000);
			axi4_lite_write(axiMasterWr, 'h40, 'h2000);
			axi4_lite_write(axiMasterWr, 'h50, 'h112200334400);
			axi4_lite_write(axiMasterWr, 'h60, 'h550000660077);
			axi4_lite_write(axiMasterWr, 'h70, 'hAABB);
			axi4_lite_write(axiMasterWr, 'h00, 1);
			enableReceive <= True;
			par
				for (ir <= 0; ir < 40; ir <= ir + 1) action
					let f = EthernetFrame {
						srcMac: 'h112200334400,
						dstMac: 'h550000660077,
						ethType: 'hAABB,
						len: 128 				// 8192 / 64
					};
					frameQueue.enq(f);
				endaction
				for (jr <= 0; jr < 40; jr <= jr + 1) action
					doneFifo.deq();
				endaction
				seq
					delay(500);
					enableReceive <= False;
					delay(2000);
					enableReceive <= True;
				endseq
			endpar
			await(dut.intr());
			axi4_lite_read(axiMasterRd, 'h10);
			action
				let r <- axi4_lite_read_response(axiMasterRd);
				checkResult(r, 10 * 'h2000 / 64, 0, 0, True);
			endaction

			printColorTimed(BLUE, $format("------------------------"));
			printColorTimed(BLUE, $format("Transmit 20000 frames"));
			printColorTimed(BLUE, $format("------------------------"));
			ignoreWrongData <= False;
			writeBeatCount <= 0;
			totalBeatCount <= 0;
			writeAddr <= 'h20000;
			axi4_lite_write(axiMasterWr, 'h20, 'h20000);
			axi4_lite_write(axiMasterWr, 'h30, 'h1000000);
			axi4_lite_write(axiMasterWr, 'h40, 'h2000);
			axi4_lite_write(axiMasterWr, 'h50, 'h112200334400);
			axi4_lite_write(axiMasterWr, 'h60, 'h550000660077);
			axi4_lite_write(axiMasterWr, 'h70, 'hAABB);
			axi4_lite_write(axiMasterWr, 'h00, 1);
			enableReceive <= True;
			par
				for (ir <= 0; ir < 20000; ir <= ir + 1) seq
					action
						let f = EthernetFrame {
							srcMac: 'h112200334400,
							dstMac: 'h550000660077,
							ethType: 'hAABB,
							len: 128 				// 8192 / 64
						};
						frameQueue.enq(f);
					endaction
					// allow to clear write FIFO after 100 transfers
					if (ir % 100 == 0)
						delay(1000);
				endseq
				for (jr <= 0; jr < 20000; jr <= jr + 1) action
					doneFifo.deq();
				endaction
			endpar
			await(dut.intr());
			axi4_lite_read(axiMasterRd, 'h10);
			action
				let r <- axi4_lite_read_response(axiMasterRd);
				checkResult(r, 20000 * 'h2000 / 64, 0, 0, False);
			endaction
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
