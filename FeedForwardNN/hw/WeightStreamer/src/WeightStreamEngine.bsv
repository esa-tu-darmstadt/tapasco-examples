package WeightStreamEngine;

import BRAM::*;

import BlueAXI::*;
import Defines::*;

interface WeightStreamEngine;
	interface AXI4_Stream_Wr_Fab#(ST_DATA_WIDTH, ST_USER_WIDTH) axi_fab;
	method Action setData(Bit#(BRAM_ADDR_WIDTH) addr, Bit#(BRAM_DATA_WIDTH) data, Bit#(BRAM_BE_WIDTH) be);
	method Action start();
endinterface

module mkWeightStreamEngine#(Integer bramSize)(WeightStreamEngine);
	AXI4_Stream_Wr#(ST_DATA_WIDTH, ST_USER_WIDTH) axiTx <- mkAXI4_Stream_Wr(2);
	let bramConfig = BRAM_Configure {
		memorySize: bramSize,
		latency: 2,
		loadFormat: None,
		outFIFODepth: 4,
		allowWriteResponseBypass: False
	};
	BRAM1PortBE#(Bit#(BRAM_ADDR_WIDTH), Bit#(BRAM_DATA_WIDTH), BRAM_BE_WIDTH) bram <- mkBRAM1ServerBE(bramConfig);

	Reg#(Bool) active <- mkReg(False);
	Reg#(Bit#(BRAM_ADDR_WIDTH)) currAddr <- mkReg(0);
	rule requestData if (active);
		let r = BRAMRequestBE {
			writeen: 0,
			responseOnWrite: False,
			address: truncate(currAddr),
			datain: ?
		};
		bram.portA.request.put(r);
		if (currAddr == fromInteger(bramSize - 1)) begin
			currAddr <= 0;
		end
		else begin
			currAddr <=  currAddr + 1;
		end
	endrule

	rule streamData;
		let d <- bram.portA.response.get();
		let p = AXI4_Stream_Pkg {
			data: d,
			user: 0,
			keep: unpack(-1),
			dest: 0,
			last: True
		};
		axiTx.pkg.put(p);
	endrule

	Wire#(Tuple3#(Bit#(BRAM_ADDR_WIDTH), Bit#(BRAM_DATA_WIDTH), Bit#(BRAM_BE_WIDTH))) forwardWriteWire <- mkWire;
	(* descending_urgency = "writeDataToBram, requestData" *)
	rule writeDataToBram;
		match {.a, .d, .be} = forwardWriteWire;
		if (be != 0 && (bramSize == valueOf(MAX_BRAM_SIZE_PER_ENGINE) || a < fromInteger(bramSize))) begin
			let r = BRAMRequestBE {
				writeen: be,
				responseOnWrite: False,
				address: truncate(a),
				datain: d
			};
			bram.portA.request.put(r);
		end
	endrule

	interface axi_fab = axiTx.fab;
	method Action setData(Bit#(BRAM_ADDR_WIDTH) addr, Bit#(BRAM_DATA_WIDTH) data, Bit#(BRAM_BE_WIDTH) be);
		forwardWriteWire <= tuple3(addr, data, be);
	endmethod
	method Action start();
		active <= True;
	endmethod
endmodule

endpackage : WeightStreamEngine
