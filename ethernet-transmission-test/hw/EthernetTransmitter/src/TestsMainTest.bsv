package TestsMainTest;

import StmtFSM::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;
import ClientServer::*;

import TestHelper::*;
import BlueAXI::*;
import BlueLib::*;
import EthernetTransmitter::*;

typedef struct {
	Bit#(32) addr;
	UInt#(32) totalLength;
	UInt#(14) frameLength;
	UInt#(16) gap;
	Bit#(48) srcMac;
	Bit#(48) dstMac;
	Bit#(16) ethType;
} TestCase deriving (Bits, Eq, FShow);

(* synthesize *)
module [Module] mkTestsMainTest(TestHelper::TestHandler);
	AXI4_Lite_Master_Rd#(12, 64) axiMasterRd <- mkAXI4_Lite_Master_Rd(2);
	AXI4_Lite_Master_Wr#(12, 64) axiMasterWr <- mkAXI4_Lite_Master_Wr(2);
	//BRAMServerBE#(Bit#(32), Bit#(512), 64) bram <- mkBRAM2ServerBE

	BRAM_Configure cfg = defaultValue;
	BRAM2PortBE#(Bit#(16), Bit#(512), 64) bram <- mkBRAM2ServerBE(cfg);
	BlueAXIBRAM#(32, 512, 1) axiBram <- mkBlueAXIBRAM(bram.portA);
	AXI4_Stream_Rd#(512, 0) axisRx <- mkAXI4_Stream_Rd(2);
	AXI4_Stream_Wr#(512, 0) axisTx <- mkAXI4_Stream_Wr(2);
	EthernetTransmitter dut <- mkEthernetTransmitter();
	mkConnection(axiMasterRd.fab, dut.s_ctrl_rd);
	mkConnection(axiMasterWr.fab, dut.s_ctrl_wr);
	mkConnection(dut.axi_rd_fab, axiBram.rd);
	mkConnection(dut.axi_wr_fab, axiBram.wr);
	mkConnection(dut.tx_fab, axisRx.fab);
	mkConnection(axisTx.fab, dut.rx_fab);

	rule discardWriteResp;
		let r <- axi4_lite_write_response(axiMasterWr);
	endrule

	Reg#(TestCase) testcase <- mkReg(?);
	Reg#(Bit#(512)) payloadOff <- mkReg(0);
	Reg#(Bool) rxActive <- mkReg(False);
	Reg#(Bit#(512)) beatCount <- mkReg(0);
	Reg#(UInt#(9)) frameBeatCount <- mkReg(0);
	rule checkHeader (!rxActive);
		let p <- axisRx.pkg.get();
		Ethernet e = unpack(p.data);
		if (e.src_mac != testcase.srcMac) begin
			printColorTimed(RED, $format("ERROR: Wrong source MAC"));
			$finish;
		end
		if (e.dst_mac != testcase.dstMac) begin
			printColorTimed(RED, $format("ERROR: Wrong destination MAC"));
			$finish;
		end
		if (e.ether_type != testcase.ethType) begin
			printColorTimed(RED, $format("ERROR: Wrong ethernet type"));
			$finish;
		end
		if (extend(e.payload) != beatCount + payloadOff) begin
			printColorTimed(RED, $format("ERROR: Wrong payload in header"));
			$finish;
		end
		rxActive <= True;
		beatCount <= beatCount + 1;
		frameBeatCount <= 1;
	endrule

	rule checkFrame if (rxActive);
		let p <- axisRx.pkg.get();
		if (p.last) begin
			if (p.data != 0) begin
				printColorTimed(RED, $format("ERROR: Wrong payload in last beat"));
				$finish;
			end
			if (frameBeatCount != truncate(testcase.frameLength >> 6)) begin
				printColorTimed(RED, $format("ERROR: Frame has wrong length"));
				$finish;
			end
			rxActive <= False;
		end
		else begin
			if (p.data >> 112 != beatCount + payloadOff) begin
				printColorTimed(RED, $format("ERROR: Wrong payload"));
				$finish;
			end
			beatCount <= beatCount + 1;
			frameBeatCount <= frameBeatCount + 1;
		end
	endrule

	function Stmt genTestStmt(TestCase t);
		return seq
			testcase <= t;
			payloadOff <= extend(t.addr) >> 6;
			frameBeatCount <= 0;
			beatCount <= 0;
			axi4_lite_write(axiMasterWr, 'h20, extend(t.addr));
			axi4_lite_write(axiMasterWr, 'h30, pack(extend(t.totalLength)));
			axi4_lite_write(axiMasterWr, 'h40, pack(extend(t.frameLength)));
			axi4_lite_write(axiMasterWr, 'h50, pack(extend(t.gap)));
			axi4_lite_write(axiMasterWr, 'h60, extend(t.srcMac));
			axi4_lite_write(axiMasterWr, 'h70, extend(t.dstMac));
			axi4_lite_write(axiMasterWr, 'h80, extend(t.ethType));
			axi4_lite_write(axiMasterWr, 'h00, 1);
			await(dut.intr());
		endseq;
	endfunction

	let t0 = TestCase {
		addr: 'h10000,
		totalLength: 'h40000,
		frameLength: 'h2000,
		gap: 0,
		srcMac: 'h560045F5EE01,
		dstMac: 'hD40045F55000,
		ethType: 'h12BB
	};
	FSM f0 <- mkFSM(genTestStmt(t0));
	Reg#(UInt#(32)) ir <- mkReg(0);
	Stmt s = {
		seq
			printColorTimed(BLUE, $format("Initialize memory"));
			for (ir <= 1024; ir < 100000; ir <= ir + 1) action
				let req = BRAMRequestBE {
					writeen: unpack(-1),
					responseOnWrite: False,
					address: truncate(pack(ir)),
					datain: extend(pack(ir))
				};
				bram.portB.request.put(req);
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
