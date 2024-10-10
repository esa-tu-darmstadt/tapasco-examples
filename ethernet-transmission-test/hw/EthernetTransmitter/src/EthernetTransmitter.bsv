package EthernetTransmitter;

import FIFO::*;
import GetPut::*;
import DReg::*;

import BlueAXI::*;

typedef enum {IDLE, RUNNING, INTR} State deriving (Bits, Eq, FShow);
typedef enum {IDLE, TRANSMIT, WAIT} TXState deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(400) payload;
	Bit#(16) ether_type;
	Bit#(48) src_mac;
	Bit#(48) dst_mac;
} Ethernet deriving(Eq, Bits, FShow);

interface EthernetTransmitter;
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
module mkEthernetTransmitter(EthernetTransmitter);
	AXI4_Master_Rd#(32, 512, 1, 0) axiRd <- mkAXI4_Master_Rd(2, 2, False);
	AXI4_Master_Wr#(32, 512, 1, 0) axiWr <- mkAXI4_Master_Wr_Dummy();

	AXI4_Stream_Rd#(512, 0) axiRx <- mkAXI4_Stream_Rd_Dummy;
	AXI4_Stream_Wr#(512, 0) axiTx <- mkAXI4_Stream_Wr(2);

	Reg#(Bool) startReg <- mkDReg(False);
	Reg#(Bit#(32)) baseAddr <- mkReg(0);
	Reg#(UInt#(32)) totalLen <- mkReg(0);
	Reg#(UInt#(14)) frameLen <- mkReg(0);
	Reg#(UInt#(16)) gapCycles <- mkReg(0);
	Reg#(Bit#(48)) srcMac <- mkReg(0);
	Reg#(Bit#(48)) dstMac <- mkReg(0);
	Reg#(Bit#(16)) ethType <- mkReg(0);
	List#(RegisterOperator#(12, 64)) ops = Nil;
	ops = registerHandler('h00, startReg, ops);
	ops = registerHandler('h20, baseAddr, ops);
	ops = registerHandler('h30, totalLen, ops);
	ops = registerHandler('h40, frameLen, ops);
	ops = registerHandler('h50, gapCycles, ops);
	ops = registerHandler('h60, srcMac, ops);
	ops = registerHandler('h70, dstMac, ops);
	ops = registerHandler('h80, ethType, ops);
	GenericAxi4LiteSlave#(12, 64) axiCtrlSlave <- mkGenericAxi4LiteSlave(ops, 2, 2);

	Reg#(State) state <- mkReg(IDLE);
	Reg#(Bit#(32)) readAddr <- mkReg(0);
	Reg#(UInt#(20)) outstandingBursts <- mkReg(0);
	Reg#(UInt#(9)) frameBeats <- mkReg(0);
	Reg#(UInt#(26)) totalFrameCount <- mkReg(0);
	rule initModule if (state == IDLE && startReg);
		state <= RUNNING;
		readAddr <= baseAddr;
		outstandingBursts <= truncate(totalLen >> 12);
		frameBeats <= truncate(frameLen >> 6);
		totalFrameCount <= 0;
	endrule

	rule issueMemReadRequest if (state == RUNNING && outstandingBursts > 0);
		axi4_read_data(axiRd, readAddr, 63);
		readAddr <= readAddr + 'h1000;
		outstandingBursts <= outstandingBursts - 1;
	endrule

	FIFO#(Bit#(512)) memDataBuffer <- mkSizedFIFO(160);
	Reg#(UInt#(9)) receiveBeatCount <- mkReg(1);
	FIFO#(Bit#(0)) txTokenFifo <- mkSizedFIFO(16);
	rule receiveMemData if (state == RUNNING);
		let d <- axi4_read_response(axiRd);
		memDataBuffer.enq(d);
		if (receiveBeatCount == frameBeats) begin
			txTokenFifo.enq(0);
			receiveBeatCount <= 1;
		end
		else begin
			receiveBeatCount <= receiveBeatCount + 1;
		end
	endrule

	Reg#(TXState) txState <- mkReg(IDLE);
	Reg#(UInt#(9)) txCount <- mkReg(0);
	Reg#(Bit#(112)) remainingData <- mkReg(0);
	rule startTransmit if (state == RUNNING && txState == IDLE);
		txTokenFifo.deq();
		let d = memDataBuffer.first();
		memDataBuffer.deq();
		remainingData <= d[511:400];
		let e = Ethernet {
			src_mac: srcMac,
			dst_mac: dstMac,
			ether_type: ethType,
			payload: d[399:0]
		};
		axiTx.pkg.put(AXI4_Stream_Pkg {
			data: pack(e),
			keep: unpack(-1),
			last: False,
			user: 0,
			dest: 0
		});
		txCount <= 1;
		txState <= TRANSMIT;

		// do not increment total frame beat counter here since we have one additional beat per
		// frame due to the Ethernet header
	endrule

	rule transmit if (state == RUNNING && txState == TRANSMIT && txCount != frameBeats);
		let d = memDataBuffer.first();
		memDataBuffer.deq();
		axiTx.pkg.put(AXI4_Stream_Pkg {
			data: {d[399:0], remainingData},
			keep: unpack(-1),
			last: False,
			user: 0,
			dest: 0
		});
		remainingData <= d[511:400];
		txCount <= txCount + 1;
		totalFrameCount <= totalFrameCount + 1;
	endrule

	Reg#(UInt#(16)) waitCount <- mkReg(0);
	rule transmitLast if (state == RUNNING && txState == TRANSMIT && txCount == frameBeats);
		axiTx.pkg.put(AXI4_Stream_Pkg {
			data: extend(remainingData),
			keep: unpack(-1),
			last: True,
			user: 0,
			dest: 0
		});
		txState <= WAIT;
		waitCount <= 0;
		totalFrameCount <= totalFrameCount + 1;
	endrule

	rule waitPeriod if (txState == WAIT);
		if (waitCount == gapCycles) begin
			txState <= IDLE;
		end
		else begin
			waitCount <= waitCount + 1;
		end
	endrule

	Reg#(Bool) intrReg <- mkDReg(False);
	Reg#(UInt#(4)) intrCount <- mkReg(0);
	rule checkDone if (state == RUNNING && totalFrameCount == truncate(totalLen >> 6));
		state <= INTR;
		intrCount <= 0;
	endrule

	rule raiseIntr if (state == INTR);
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
	interface tx_fab = axiTx.fab;
	interface intr = intrReg;
endmodule

endpackage
