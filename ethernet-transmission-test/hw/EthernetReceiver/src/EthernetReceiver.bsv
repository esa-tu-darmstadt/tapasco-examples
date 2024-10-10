package EthernetReceiver;

import FIFO::*;
import FIFOF::*;
import GetPut::*;
import DReg::*;

import BlueAXI::*;

typedef enum {IDLE, RUNNING, FINISH_WRITE, INTR} State deriving (Bits, Eq, FShow);
typedef enum {IDLE, RECEIVE, DROP} RXState deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(400) payload;
	Bit#(16) ether_type;
	Bit#(48) src_mac;
	Bit#(48) dst_mac;
} Ethernet deriving(Eq, Bits, FShow);

interface EthernetReceiver;
	(* prefix = "S_AXI_CTRL" *)
	interface AXI4_Lite_Slave_Rd_Fab#(12, 64) s_ctrl_rd;
	(* prefix = "S_AXI_CTRL" *)
	interface AXI4_Lite_Slave_Wr_Fab#(12, 64) s_ctrl_wr;

	(* prefix = "M_AXI_MEM" *)
	interface AXI4_Master_Rd_Fab#(32, 512, 1, 0) axi_rd_fab;
	(* prefix = "M_AXI_MEM" *)
	interface AXI4_Master_Wr_Fab#(32, 512, 1, 0) axi_wr_fab;

	(* prefix = "AXIS_RX" *)
	interface AXI4_Stream_Rd_Fab#(512, 0) rx_fab;
	(* prefix = "AXIS_TX" *)
	interface AXI4_Stream_Wr_Fab#(512, 0) tx_fab;

	(* always_ready, always_enabled *)
	method Bool intr();
endinterface

(* synthesize, default_clock_osc = "aclk", default_reset = "aresetn" *)
module mkEthernetReceiver(EthernetReceiver);
	AXI4_Master_Rd#(32, 512, 1, 0) axiRd <- mkAXI4_Master_Rd_Dummy;
	AXI4_Master_Wr#(32, 512, 1, 0) axiWr <- mkAXI4_Master_Wr(2, 2, 2, False);

	AXI4_Stream_Rd#(512, 0) axiRx <- mkAXI4_Stream_Rd(2);
	AXI4_Stream_Wr#(512, 0) axiTxDummy <- mkAXI4_Stream_Wr_Dummy;

	Reg#(Bool) startReg <- mkDReg(False);
	Reg#(Bit#(32)) receivedBeatCount <- mkReg(0);
	Reg#(Bit#(12)) wrongHeaderCount <- mkReg(0);
	Reg#(Bit#(12)) wrongFrameLenCount <- mkReg(0);
	Reg#(Bool) dropBeatError <- mkReg(False);
	Reg#(Bit#(32)) baseAddr <- mkReg(0);
	Reg#(UInt#(32)) runCycles <- mkReg(0);
	Reg#(UInt#(14)) frameLen <- mkReg(0);
	Reg#(Bit#(48)) srcMac <- mkReg(0);
	Reg#(Bit#(48)) dstMac <- mkReg(0);
	Reg#(Bit#(16)) ethType <- mkReg(0);
	List#(RegisterOperator#(12, 64)) ops = Nil;
	ops = registerHandler('h00, startReg, ops);

	function ActionValue#(Bit#(64)) readResult(AXI4_Lite_Prot prot);
		actionvalue
			Bit#(64) ret = 0;
			ret[31:0] = receivedBeatCount;
			ret[43:32] = wrongHeaderCount;
			ret[55:44] = wrongFrameLenCount;
			ret[56] = pack(dropBeatError);
			return ret;
		endactionvalue
	endfunction
	ops = List::cons(tagged Read ReadOperation {index: 'h10, fun: readResult}, ops);
	ops = registerHandler('h20, baseAddr, ops);
	ops = registerHandler('h30, runCycles, ops);
	ops = registerHandler('h40, frameLen, ops);
	ops = registerHandler('h50, srcMac, ops);
	ops = registerHandler('h60, dstMac, ops);
	ops = registerHandler('h70, ethType, ops);
	GenericAxi4LiteSlave#(12, 64) axiCtrlSlave <- mkGenericAxi4LiteSlave(ops, 2, 2);

	Reg#(State) state <- mkReg(IDLE);
	Reg#(UInt#(32)) cycleCount <- mkReg(0);
	Reg#(Bit#(32)) writeAddr <- mkReg(0);
	Reg#(UInt#(9)) frameBeatLen <- mkReg(0);
	Reg#(UInt#(9)) rxCount <- mkReg(0);
	Reg#(RXState) rxState <- mkReg(IDLE);
	FIFOF#(Bit#(512)) bufferFifo <- mkSizedFIFOF(256);
	Reg#(UInt#(6)) tokenCount <- mkReg(0);
	rule initModule if (state == IDLE && startReg);
		receivedBeatCount <= 0;
		wrongHeaderCount <= 0;
		wrongFrameLenCount <= 0;
		dropBeatError <= False;
		state <= RUNNING;
		cycleCount <= 0;
		writeAddr <= baseAddr;
		frameBeatLen <= truncate(frameLen >> 6);
		rxCount <= 0;
		rxState <= IDLE;
		bufferFifo.clear();
		tokenCount <= 0;
	endrule

	Reg#(Bit#(400)) beginningData <- mkReg(0);
	rule receiveHeader if (state == RUNNING && rxState == IDLE);
		let p <- axiRx.pkg.get();
		Ethernet e = unpack(p.data);
		if (e.src_mac == srcMac && e.dst_mac == dstMac && e.ether_type == ethType) begin
			beginningData <= e.payload;
			rxCount <= 1;
			rxState <= RECEIVE;
		end
		else begin
			wrongHeaderCount <= wrongHeaderCount + 1;
			rxState <= DROP;
		end
		// $display(fshow(e));
	endrule

	RWire#(Bit#(512)) forwardBeatWire <- mkRWire;
	rule receivePackets if (state == RUNNING && rxState == RECEIVE);
		let p <- axiRx.pkg.get();
		if (p.last) begin
			rxState <= IDLE;
			if (rxCount != frameBeatLen) begin
				wrongFrameLenCount <= wrongFrameLenCount + 1;
			end
		end
		else begin
			rxCount <= rxCount + 1;
		end
		forwardBeatWire.wset({p.data[111:0], beginningData});
		beginningData <= p.data[511:112];
	endrule

	FIFOF#(Bit#(0)) writeTokenFifo <- mkSizedFIFOF(4);
	rule enqueue if (forwardBeatWire.wget() matches tagged Valid .b);
		bufferFifo.enq(b);
		receivedBeatCount <= receivedBeatCount + 1;
		// $display("receivedBeatCount = %d", receivedBeatCount);
		if (tokenCount == 63) begin
			tokenCount <= 0;
			writeTokenFifo.enq(0);
		end
		else begin
			tokenCount <= tokenCount + 1;
		end
	endrule

	rule detectBeatDrop if (isValid(forwardBeatWire.wget()) && !bufferFifo.notFull());
		dropBeatError <= True;
	endrule

	rule dropPackets if (state == RUNNING && rxState == DROP);
		let p <- axiRx.pkg.get();
		if (p.last) begin
			rxState <= IDLE;
		end
	endrule

	FIFOF#(Bit#(0)) activeWrites <- mkSizedFIFOF(4);
	FIFOF#(Bit#(0)) outstandingResponses <- mkSizedFIFOF(4);
	rule issueWriteRequest;
		writeTokenFifo.deq();
		axi4_write_addr(axiWr, writeAddr, 63);
		writeAddr <= writeAddr + 'h1000;
		activeWrites.enq(0);
	endrule

	Reg#(UInt#(8)) beatCount <- mkReg(0);
	rule sendDataBeat;
		let d = bufferFifo.first();
		bufferFifo.deq();
		Bool last = beatCount == 63;
		axi4_write_data(axiWr, d, unpack(-1), last);
		if (last) begin
			activeWrites.deq();
			outstandingResponses.enq(0);
			beatCount <= 0;
		end
		else begin
			beatCount <= beatCount + 1;
		end
	endrule

	rule discardWriteResponse;
		let r <- axi4_write_response(axiWr);
		outstandingResponses.deq();
	endrule

	Reg#(Bool) intrReg <- mkDReg(False);
	Reg#(UInt#(4)) intrCount <- mkReg(0);
	rule incrCycleCount if (state == RUNNING && cycleCount != runCycles);
		cycleCount <= cycleCount + 1;
	endrule

	rule checkDone if (state == RUNNING && cycleCount == runCycles);
		state <= FINISH_WRITE;
	endrule

	rule finishWrite if (state == FINISH_WRITE && !writeTokenFifo.notEmpty() && !activeWrites.notEmpty && !outstandingResponses.notEmpty());
		intrCount <= 0;
		state <= INTR;
	endrule

	rule setIntr if (state == INTR);
		intrReg <= True;
		if (intrCount == 15) begin
			state <= IDLE;
		end
		intrCount <= intrCount + 1;
	endrule

	interface s_ctrl_rd = axiCtrlSlave.s_rd;
	interface s_ctrl_wr = axiCtrlSlave.s_wr;
	interface axi_rd_fab = axiRd.fab;
	interface axi_wr_fab = axiWr.fab;
	interface rx_fab = axiRx.fab;
	interface tx_fab = axiTxDummy.fab;
	interface intr = intrReg;
endmodule

endpackage
