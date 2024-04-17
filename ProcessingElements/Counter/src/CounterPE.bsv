package CounterPE;

import DReg :: *;
import BlueAXI :: *;

// Configuration Interface
typedef 12 CONFIG_ADDR_WIDTH;
typedef 64 CONFIG_DATA_WIDTH;

interface CounterPE;
    (*prefix="S_AXI"*) interface AXI4_Lite_Slave_Rd_Fab#(CONFIG_ADDR_WIDTH, CONFIG_DATA_WIDTH) s_rd;
    (*prefix="S_AXI"*) interface AXI4_Lite_Slave_Wr_Fab#(CONFIG_ADDR_WIDTH, CONFIG_DATA_WIDTH) s_wr;
    (* always_ready *) method Bool interrupt();
endinterface

module mkCounter(CounterPE);

    Reg#(Bool) start <- mkReg(False);
    Reg#(Bit#(CONFIG_DATA_WIDTH)) result <- mkReg(0);
    Reg#(Bit#(CONFIG_DATA_WIDTH)) param <- mkReg(0);

    List#(RegisterOperator#(axiAddrWidth, CONFIG_DATA_WIDTH)) operators = Nil;
    operators = registerHandler('h00, start, operators);
    operators = registerHandler('h10, result, operators);
    operators = registerHandler('h20, param, operators);
    GenericAxi4LiteSlave#(CONFIG_ADDR_WIDTH, CONFIG_DATA_WIDTH) s_config <- mkGenericAxi4LiteSlave(operators, 1, 1);

    Reg#(Bool) interruptR <- mkDReg(False);

    rule counting (start && result < param);
        result <= result + 1;
    endrule

    rule done (start && result == param);
        start <= False;
        interruptR <= True;
        result <= 0;
    endrule

    interface s_rd = s_config.s_rd;
    interface s_wr = s_config.s_wr;

    method Bool interrupt = interruptR;

endmodule

endpackage
