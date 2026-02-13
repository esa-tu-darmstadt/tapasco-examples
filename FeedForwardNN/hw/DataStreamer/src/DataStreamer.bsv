package DataStreamer;

import DReg::*;
import Vector::*;
import FIFO::*;
import GetPut::*;

import BlueAXI::*;
import BlueLib::*;

typedef enum {IDLE, RUNNING, INTR} State deriving (Bits, Eq, FShow);

typedef struct {
	UInt#(10) len;
	Bool trigger;
} TXBurst deriving (Bits, Eq, FShow);

typedef 12 CTRL_ADDR_WIDTH;
typedef 64 CTRL_DATA_WIDTH;
typedef 128 ST_DATA_WIDTH;
typedef 0 ST_USER_WIDTH;
typedef 512 DMA_DATA_WIDTH;
typedef 0 DMA_USER_WIDTH;

typedef 268435456 MAX_NUM_BATCHES;
typedef TMax#(16, TAdd#(TLog#(MAX_NUM_BATCHES), 1)) NUM_BATCHES_WIDTH;
typedef TSub#(NUM_BATCHES_WIDTH, 4) OUTSTANDING_BEATS_WIDTH;

interface DataStreamer;
	(* prefix = "S_AXI_CTRL" *)
	interface AXI4_Lite_Slave_Rd_Fab#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) s_rd;
	(* prefix = "S_AXI_CTRL" *)
	interface AXI4_Lite_Slave_Wr_Fab#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) s_wr;

	(* always_ready, always_enabled *)
	method Bool intr();

	(* prefix = "S_AXIS_DMA" *)
	interface AXI4_Stream_Rd_Fab#(DMA_DATA_WIDTH, DMA_USER_WIDTH) h2c_fab;
	(* prefix = "M_AXIS_DMA" *)
	interface AXI4_Stream_Wr_Fab#(DMA_DATA_WIDTH, DMA_USER_WIDTH) c2h_fab;

	(* prefix = "M_AXIS_FEAT" *)
	interface Vector#(4, AXI4_Stream_Wr_Fab#(ST_DATA_WIDTH, ST_USER_WIDTH)) feature_st_fabs;
	(* prefix = "S_AXIS_RES" *)
	interface AXI4_Stream_Rd_Fab#(ST_DATA_WIDTH, ST_USER_WIDTH) result_st_fab;
endinterface

(* synthesize, default_clock_osc = "aclk", default_reset = "aresetn" *)
module mkDataStreamer(DataStreamer intf);
	AXI4_Stream_Rd#(DMA_DATA_WIDTH, DMA_USER_WIDTH) h2cRx <- mkAXI4_Stream_Rd(2); // TODO fifo size
	AXI4_Stream_Wr#(DMA_DATA_WIDTH, DMA_USER_WIDTH) c2hTx <- mkAXI4_Stream_Wr(2); // TODO fifo size

	Vector#(4, AXI4_Stream_Wr#(ST_DATA_WIDTH, ST_USER_WIDTH)) axisTx <- replicateM(mkAXI4_Stream_Wr(2));
	AXI4_Stream_Rd#(ST_DATA_WIDTH, ST_USER_WIDTH) axisRx <- mkAXI4_Stream_Rd(2);

	Reg#(Bool) startReg <- mkDReg(False);
	Reg#(UInt#(32)) cycleCnt <- mkReg(0);
	Reg#(UInt#(NUM_BATCHES_WIDTH)) numBatches <- mkReg(0);
	List#(RegisterOperator#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH)) operators = Nil;
	operators = registerHandler('h00, startReg, operators);
	operators = registerHandlerRO('h10, cycleCnt, operators);
	operators = registerHandler('h20, numBatches, operators);
	GenericAxi4LiteSlave#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) axiCtrlSlave <- mkGenericAxi4LiteSlave(operators, 2, 2);

	Reg#(State) state <- mkReg(IDLE);
	Reg#(UInt#(OUTSTANDING_BEATS_WIDTH)) outstandingTxBeats <- mkReg(0);
	rule initModule if (state == IDLE && startReg);
		outstandingTxBeats <= truncate(numBatches >> 4);
		cycleCnt <= 0;
		state <= RUNNING;
	endrule

	rule incrCycleCnt if (state == RUNNING);
		cycleCnt <= cycleCnt + 1;
	endrule

	// ---------------------------------------------
	// Receive data from QDMA
	// ---------------------------------------------
	Vector#(16, FIFO#(Bit#(128))) sortingFifos <- replicateM(mkSizedFIFO(4));

	// Put data round robin into sorting fifos
	Reg#(UInt#(2)) rxCnt <- mkReg(0);
	for (Integer i = 0; i < 4; i = i + 1) begin
		rule receiveInputData if (state == RUNNING && rxCnt == fromInteger(i));
			let p <- h2cRx.pkg.get();
			Vector#(4, Bit#(128)) v = unpack(p.data);
			for (Integer j = 0; j < 4; j = j + 1) begin
				Integer idx = i * 4 + j;
				sortingFifos[idx].enq(v[j]);
			end
			rxCnt <= rxCnt + 1;
		endrule
	end


	// ---------------------------------------------
	// Send data to AI Engines
	// ---------------------------------------------

	// For each PLIO stream take always four values each FIFO before
	// switching to the next one to achieve 4x4 tiling pattern
	for (Integer i = 0; i < 4; i = i + 1) begin
		Reg#(UInt#(2)) sel <- mkReg(0);
		Reg#(UInt#(2)) cnt <- mkReg(0);
		FIFO#(Tuple2#(Bit#(128), Bool)) selDataFifo <- mkFIFO;
		for (Integer j = 0; j < 4; j = j + 1) begin
			rule selData if (sel == fromInteger(j));
				Integer idx = i * 4 + j;
				let d = sortingFifos[idx].first();
				sortingFifos[idx].deq();

				Bool last = cnt == 3;
				selDataFifo.enq(tuple2(d, last));
				cnt <= cnt + 1;
				if (last) begin
					sel <= sel + 1;
				end
			endrule
		end

		rule sendData;
			match {.d, .last} = selDataFifo.first();
			selDataFifo.deq();
			let p = AXI4_Stream_Pkg {
				data: d,
				user: 0,
				keep: unpack(-1),
				dest: 0,
				last: last
			};
			axisTx[i].pkg.put(p);
		endrule
	end


	// ---------------------------------------------
	// Receive data to AI Engines
	// ---------------------------------------------
	FIFO#(Bit#(512)) outWordFifo <- mkFIFO;
	Vector#(3, Reg#(Bit#(128))) accReg <- replicateM(mkReg(0));
	Reg#(UInt#(2)) accCnt <- mkReg(0);
	rule buffer if (accCnt < 3);
		let p <- axisRx.pkg.get();
		accReg[accCnt] <= p.data;
		accCnt <= accCnt + 1;
	endrule

	rule accumulate if (accCnt == 3);
		let p <- axisRx.pkg.get();
		Vector#(4, Bit#(128)) v = newVector();
		for (Integer i = 0; i < 3; i = i + 1) begin
			v[i] = accReg[i];
		end
		v[3] = p.data;
		outWordFifo.enq(pack(v));
		accCnt <= 0;
	endrule

	// ---------------------------------------------
	// Return data to QDMA
	// ---------------------------------------------
	Reg#(Maybe#(TXBurst)) activeBurst <- mkReg(tagged Invalid);
	Reg#(UInt#(10)) burstCnt <- mkReg(0);
	Reg#(UInt#(4)) txPktCnt <- mkReg(0);
	Integer maxBurstLen = 'h8000 / (512 / 8);
	rule startBurst if (state == RUNNING && outstandingTxBeats != 0 && !isValid(activeBurst));
		Bool lastBurst = !(outstandingTxBeats > fromInteger(maxBurstLen));
		let len = lastBurst ? outstandingTxBeats : fromInteger(maxBurstLen);

		TXBurst txBurst;
		txBurst.len = truncate(len);
		if (txPktCnt == 7 || lastBurst) begin
			txBurst.trigger = True;
			txPktCnt <= 0;
		end
		else begin
			txPktCnt <= txPktCnt + 1;
			txBurst.trigger = False;
		end
		activeBurst <= tagged Valid txBurst;
		burstCnt <= 0;
	endrule

	rule transmitData if (state == RUNNING && isValid(activeBurst));
		let d = outWordFifo.first();
		outWordFifo.deq();
		match TXBurst {len: .l, trigger: .t} = fromMaybe(?, activeBurst);
		let lenBytes = extend(l) << 6; // len * (512 / 8)
		let burstCntNext = burstCnt + 1;
		Bool last = burstCntNext == l;

		let p = AXI4_Stream_Pkg {
			data: pack(d),
			user: 0,
			keep: unpack(-1),
			dest: 0,
			last: last
		};
		c2hTx.pkg.put(p);

		// update counter
		outstandingTxBeats <= outstandingTxBeats - 1;
		burstCnt <= burstCntNext;
		if (last)
			activeBurst <= tagged Invalid;
	endrule


	// ---------------------------------------------
	// Interrupt
	// ---------------------------------------------
	Reg#(UInt#(4)) intrCnt <- mkReg(0);
	rule checkFinish if (state == RUNNING && outstandingTxBeats == 0 && !isValid(activeBurst));
		printColorTimed(YELLOW, $format("[checkFinish] Send interrupt"));
		state <= INTR;
		intrCnt <= 0;
	endrule

	Reg#(Bool) intrReg <- mkDReg(False);
	rule setIntr if (state == INTR);
		intrReg <= True;
		if (intrCnt == 15)
			state <= IDLE;
		else
			intrCnt <= intrCnt + 1;
	endrule

	// ---------------------------------------------
	// Interfaces
	// ---------------------------------------------
	Vector#(4, AXI4_Stream_Wr_Fab#(ST_DATA_WIDTH, ST_USER_WIDTH)) st_vec;
	for (Integer i = 0; i < 4; i = i + 1) begin
		st_vec[i] = axisTx[i].fab;
	end

	interface s_rd = axiCtrlSlave.s_rd;
	interface s_wr = axiCtrlSlave.s_wr;
	interface h2c_fab = h2cRx.fab;
	interface c2h_fab = c2hTx.fab;

	interface feature_st_fabs = st_vec;
	interface result_st_fab = axisRx.fab;

	interface intr = intrReg;
endmodule

endpackage
