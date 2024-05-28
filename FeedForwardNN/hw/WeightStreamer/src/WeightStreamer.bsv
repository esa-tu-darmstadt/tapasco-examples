package WeightStreamer;

import DReg::*;
import Vector::*;
import GetPut::*;

import BlueAXI::*;
import BlueLib::*;
import Defines::*;
import WeightStreamEngine::*;

typedef enum { IDLE, RUNNING } State deriving (Bits, Eq, FShow);

interface WeightStreamer;
	(* prefix = "S_AXI_CTRL" *)
	interface AXI4_Lite_Slave_Rd_Fab#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) s_ctrl_rd;
	(* prefix = "S_AXI_CTRL" *)
	interface AXI4_Lite_Slave_Wr_Fab#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) s_ctrl_wr;
	(* prefix = "S_AXI_BRAM" *)
	interface AXI4_Lite_Slave_Rd_Fab#(MEM_AXI_ADDR_WIDTH, CTRL_DATA_WIDTH) s_bram_rd;
	(* prefix = "S_AXI_BRAM" *)
	interface AXI4_Lite_Slave_Wr_Fab#(MEM_AXI_ADDR_WIDTH, CTRL_DATA_WIDTH) s_bram_wr;

	(* prefix = "M_AXIS_WEIGHTS" *)
	interface Vector#(NUM_STREAMS, AXI4_Stream_Wr_Fab#(ST_DATA_WIDTH, ST_USER_WIDTH)) st_fabs;

	(* always_ready, always_enabled *)
	method Bool intr();
endinterface

(* synthesize, default_clock_osc = "aclk", default_reset = "aresetn" *)
module mkWeightStreamer(WeightStreamer);
	AXI4_Lite_Slave_Rd#(MEM_AXI_ADDR_WIDTH, CTRL_DATA_WIDTH) axiBramRd <- mkAXI4_Lite_Slave_Rd(2);
	AXI4_Lite_Slave_Wr#(MEM_AXI_ADDR_WIDTH, CTRL_DATA_WIDTH) axiBramWr <- mkAXI4_Lite_Slave_Wr(2);

	Reg#(Bool) startReg <- mkDReg(False);
	List#(RegisterOperator#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH)) operators = Nil;
	operators = registerHandler('h00, startReg, operators);
	GenericAxi4LiteSlave#(CTRL_ADDR_WIDTH, CTRL_DATA_WIDTH) axiCtrlSlave <- mkGenericAxi4LiteSlave(operators, 2, 2);

	Vector#(NUM_STREAMS, WeightStreamEngine) engines = newVector();
	for (Integer i = 0; i < valueOf(NUM_STREAMS); i = i + 1) begin
		if (i < valueOf(NUM_L0_STREAMS)) begin
			engines[i] <- mkWeightStreamEngine(bramSizePerEngine[0]);
		end
		else if (i < valueOf(TAdd#(NUM_L1_STREAMS, NUM_L0_STREAMS))) begin
			engines[i] <- mkWeightStreamEngine(bramSizePerEngine[1]);
		end
		else if (i < valueOf(TAdd#(TAdd#(NUM_L2_STREAMS, NUM_L1_STREAMS), NUM_L0_STREAMS))) begin
			engines[i] <- mkWeightStreamEngine(bramSizePerEngine[2]);
		end
		else begin // Layer 3
			engines[i] <- mkWeightStreamEngine(bramSizePerEngine[3]);
		end
	end

	// always respond to BRAM read requests to prevent blocking of PCIe bus
	rule handleBramRead;
		let req <- axiBramRd.request.get();
		let resp = AXI4_Lite_Read_Rs_Pkg {
			data: 0,
			resp: OKAY
		};
		axiBramRd.response.put(resp);
	endrule

	rule handleBramWrite;
		let req <- axiBramWr.request.get();

		Bool isUpper = unpack(req.addr[3]);
		Bit#(BRAM_DATA_WIDTH) data = zeroExtend(req.data);
		Bit#(BRAM_BE_WIDTH) be = zeroExtend(req.strb);
		Bit#(MEM_IFC_ADDR_WIDTH) addr = truncate(req.addr >> 4);
		if (isUpper) begin
			data = data << 64;
			be = be << 8;
		end

		Bit#(TSub#(MEM_AXI_ADDR_WIDTH, BRAM_ADDR_WIDTH)) engine_no = addr[valueOf(MEM_IFC_ADDR_WIDTH) - 1:valueOf(BRAM_ADDR_WIDTH)];
		engines[engine_no].setData(truncate(addr), data, be);

		// always return OKAY to prevent bus errors on host side
		axiBramWr.response.put(AXI4_Lite_Write_Rs_Pkg { resp: OKAY });
	endrule

	Reg#(State) state <- mkReg(IDLE);
	rule initModule if (state == IDLE && startReg);
		state <= RUNNING;
		for (Integer i = 0; i < valueOf(NUM_STREAMS); i = i + 1) begin
			engines[i].start();
		end
	endrule

	Reg#(UInt#(10)) intrCnt <- mkReg(0);
	Reg#(Bool) intrEngActive <- mkReg(False);
	Reg#(Bool) intrReg <- mkReg(False);
	rule startIntrCnt if (!intrEngActive && startReg);
		intrCnt <= 0;
		intrEngActive <= True;
	endrule

	rule setIntr if (intrEngActive && !intrReg);
		if (intrCnt == 1023) begin
			intrCnt <= 0;
			intrReg <= True;
		end
		else begin
			intrCnt <= intrCnt + 1;
		end
	endrule

	rule resetIntr if (intrEngActive && intrReg);
		if (intrCnt == 15) begin
			intrReg <= False;
			intrEngActive <= False;
		end
		else begin
			intrCnt <= intrCnt + 1;
		end
	endrule

	Vector#(NUM_STREAMS, AXI4_Stream_Wr_Fab#(ST_DATA_WIDTH, ST_USER_WIDTH)) st_fab_vec = newVector();
	for (Integer i = 0; i < valueOf(NUM_STREAMS); i = i + 1) begin
		st_fab_vec[i] = engines[i].axi_fab;
	end
	interface s_ctrl_rd = axiCtrlSlave.s_rd;
	interface s_ctrl_wr = axiCtrlSlave.s_wr;
	interface s_bram_rd = axiBramRd.fab;
	interface s_bram_wr = axiBramWr.fab;
	interface st_fabs = st_fab_vec;

	method Bool intr() = intrReg;
endmodule

endpackage
